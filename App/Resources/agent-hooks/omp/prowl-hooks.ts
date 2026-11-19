// Prowl managed hook extension for Oh My Pi (docs-ai 064.010).
//
// Relays Oh My Pi's native lifecycle events to the Prowl app that launched this session through
// the bundled `prowl agents _hook` bridge, which validates the launch token, caller ancestry,
// and working directory. Observation only: nothing here changes what the agent does, every
// failure is swallowed, and nothing is written to the terminal.
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const RUNTIME = "omp";
// `session_stop` is documented as main-session only, whereas `agent_end` fires once per
// in-process `task` sub-agent; `/new` rotates through `session_switch`.
const FORWARDED_EVENTS = [
  "session_start",
  "session_switch",
  "session_stop",
  "tool_approval_requested",
  "session_shutdown",
];
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
// must share one order. A bridge that hangs is killed after a bound so later events keep flowing.
//
// Only the main session's `session_shutdown` waits on the queue. Oh My Pi waits for a promise
// that a handler returns, and its print mode (`omp -p`) exits milliseconds after the shutdown;
// without the wait, the `session_stop` and the shutdown queued just before are lost. A turn end
// never waits, so the TUI does not stall on the bridge.
const DELIVERY_TIMEOUT_MS = 5000;
const EXIT_DRAIN_TIMEOUT_MS = 5000;
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

function drain(): Promise<void> {
  const pending = shared[QUEUE_KEY] ?? Promise.resolve();
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, EXIT_DRAIN_TIMEOUT_MS);
    pending.then(() => {
      clearTimeout(timer);
      resolve();
    });
  });
}

// Returns whether the event was queued for delivery.
function relay(name: string, event: any, ctx: any): boolean {
  try {
    if (!process.env[TOKEN_VARIABLE]) return false;
    // `/reload` swaps the extension instances: the old one reports `session_shutdown` and the
    // new one `session_start`, both with reason "reload" and the same session id. The session
    // neither ends nor changes, so neither is forwarded — a late shutdown would otherwise read
    // as the live session ending.
    if (event?.reason === "reload") return false;
    let sessionId = ctx?.sessionManager?.getSessionId?.();
    if (typeof sessionId !== "string" || sessionId.length === 0) return false;
    const parent = parentSessionId(ctx);
    if (parent !== undefined) {
      if (name !== "tool_approval_requested") return false;
      sessionId = parent;
    }
    const reason = typeof event?.reason === "string" ? event.reason : event?.toolName;
    const payload = {
      hook_event_name: name,
      session_id: sessionId,
      cwd: typeof ctx?.cwd === "string" ? ctx.cwd : process.cwd(),
      reason: typeof reason === "string" ? reason : undefined,
    };
    enqueue(name, payload);
    return true;
  } catch {
    // fail-open: the runtime must never notice a hook problem
    return false;
  }
}

export default function (pi: any): void {
  for (const name of FORWARDED_EVENTS) {
    try {
      pi.on(name, (event: any, ctx: any) => {
        const queued = relay(name, event, ctx);
        if (queued && name === "session_shutdown") return drain();
      });
    } catch {
      // an unknown event name on a newer Oh My Pi is not an error worth surfacing
    }
  }
}
