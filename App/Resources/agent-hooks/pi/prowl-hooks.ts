// Prowl managed hook extension for Pi (docs-ai 064.010).
//
// Relays Pi's native lifecycle events to the Prowl app that launched this session through the
// bundled `prowl agents _hook` bridge, which validates the launch token, caller ancestry, and
// working directory. Observation only: nothing here changes what the agent does, every failure
// is swallowed, and nothing is written to the terminal.
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const RUNTIME = "pi";
// `agent_end` precedes `agent_settled`, Pi's documented idle point, and is not forwarded.
const FORWARDED_EVENTS = ["session_start", "agent_settled", "session_shutdown"];
const TOKEN_VARIABLE = "PROWL_AGENT_HOOK_TOKEN";
const CLI = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "prowl-cli", "prowl");

// Session files live directly in the session directory as `<timestamp>_<id>.jsonl`, where the id
// is opaque (`--session-id` accepts any name). An in-process sub-agent (Oh My Pi's `task` tool)
// runs under its own session id and stores its file *inside* the parent's session directory
// (`<timestamp>_<parent>/<Agent>.jsonl`, nested again for a sub-agent's sub-agent). The runtime
// loads a fresh extension instance for each of those sessions, so the classification must be
// stateless: a session is a sub-agent when any ancestor directory of its file is a session
// directory, and the pane's session id is that directory's id. Sub-agent lifecycle events must
// not rotate the pane's session, while an approval a sub-agent asks for still blocks the user
// and is reported under the pane's session.
const SESSION_DIRECTORY = /^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z_(.+)$/;

function parentSessionId(ctx: any): string | undefined {
  const file = ctx?.sessionManager?.getSessionFile?.();
  if (typeof file !== "string" || file.length === 0) return undefined;
  const components = file.split("/");
  for (const directory of components.slice(0, -1)) {
    const match = SESSION_DIRECTORY.exec(directory);
    if (match) return match[1];
  }
  return undefined;
}

// Deliveries are serialized process-wide: adjacent lifecycle events (Pi's `agent_settled` and
// `session_shutdown` are milliseconds apart at exit) would otherwise race as independent
// processes and could reach Prowl out of order, where a late session start clears the terminal
// evidence a wait relies on. The queue lives on `globalThis` because the runtime loads a fresh
// module instance on `/reload` and for every sub-agent session (measured), and those instances
// must share one order. The runtime callback never waits on the queue, and a bridge that hangs
// is killed after a bound so later events keep flowing.
const DELIVERY_TIMEOUT_MS = 5000;
const QUEUE_KEY = "__prowlHookDeliveries";
const shared = globalThis as unknown as Record<string, Promise<void> | undefined>;

function deliver(name: string, payload: Record<string, unknown>): Promise<void> {
  return new Promise((resolve) => {
    try {
      const child = spawn(CLI, ["agents", "_hook", RUNTIME, name], {
        stdio: ["pipe", "ignore", "ignore"],
        env: process.env,
      });
      let settled = false;
      const finish = () => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        try {
          child.kill();
        } catch {
          // already gone
        }
        finish();
      }, DELIVERY_TIMEOUT_MS);
      child.on("error", finish);
      child.on("close", finish);
      child.stdin.on("error", () => {});
      child.stdin.end(JSON.stringify(payload));
    } catch {
      resolve();
    }
  });
}

function enqueue(name: string, payload: Record<string, unknown>): void {
  const previous = shared[QUEUE_KEY] ?? Promise.resolve();
  shared[QUEUE_KEY] = previous.then(() => deliver(name, payload)).catch(() => {});
}

function relay(name: string, event: any, ctx: any): void {
  try {
    if (!process.env[TOKEN_VARIABLE]) return;
    // `/reload` swaps the extension instances: the old one reports `session_shutdown` and the
    // new one `session_start`, both with reason "reload" and the same session id. The session
    // neither ends nor changes, so neither is forwarded — a late shutdown would otherwise read
    // as the live session ending.
    if (event?.reason === "reload") return;
    let sessionId = ctx?.sessionManager?.getSessionId?.();
    if (typeof sessionId !== "string" || sessionId.length === 0) return;
    const parent = parentSessionId(ctx);
    if (parent !== undefined) {
      if (name !== "tool_approval_requested") return;
      sessionId = parent;
    }
    const payload = {
      hook_event_name: name,
      session_id: sessionId,
      cwd: typeof ctx?.cwd === "string" ? ctx.cwd : process.cwd(),
      reason: typeof event?.reason === "string" ? event.reason : undefined,
    };
    enqueue(name, payload);
  } catch {
    // fail-open: the runtime must never notice a hook problem
  }
}

export default function (pi: any): void {
  for (const name of FORWARDED_EVENTS) {
    try {
      pi.on(name, (event: any, ctx: any) => {
        relay(name, event, ctx);
      });
    } catch {
      // an unknown event name on a newer Pi is not an error worth surfacing
    }
  }
}
