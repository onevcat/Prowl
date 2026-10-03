// Prowl managed hook plugin for OpenCode (docs-ai 064.010).
//
// Relays OpenCode's bus events to the Prowl app that launched this session through the bundled
// `prowl agents _hook` bridge, which validates the launch token, caller ancestry, and working
// directory. Observation only: nothing here changes what the agent does, every failure is
// swallowed, and nothing is written to the terminal.
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const RUNTIME = "opencode";
// `session.status` duplicates `session.idle`; the `*.replied` events end a block rather than
// start one; `session.created` is tracked only to recognise sub-agent sessions.
const FORWARDED_EVENTS = new Set(["session.idle", "permission.asked", "question.asked"]);
const TOKEN_VARIABLE = "PROWL_AGENT_HOOK_TOKEN";
const CLI = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "prowl-cli", "prowl");

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

export const ProwlHooks = async ({ directory }: any) => {
  // Sub-agent sessions carry `parentID` on creation; their own `session.idle` fires long
  // before the parent's and must never read as the pane's turn ending.
  const childSessions = new Set<string>();

  function relay(name: string, sessionId: string, reason: unknown): void {
    try {
      if (!process.env[TOKEN_VARIABLE]) return;
      enqueue(name, {
        hook_event_name: name,
        session_id: sessionId,
        cwd: typeof directory === "string" ? directory : process.cwd(),
        reason: typeof reason === "string" ? reason : undefined,
      });
    } catch {
      // fail-open: the runtime must never notice a hook problem
    }
  }

  return {
    event: async ({ event }: any) => {
      try {
        const type = event?.type;
        const properties = event?.properties ?? {};
        if (type === "session.created") {
          const info = properties.info;
          const id = info?.id ?? properties.sessionID;
          if (typeof id === "string" && info?.parentID) childSessions.add(id);
          return;
        }
        if (!FORWARDED_EVENTS.has(type)) return;
        const sessionId = properties.sessionID;
        if (typeof sessionId !== "string" || sessionId.length === 0) return;
        if (childSessions.has(sessionId)) return;
        relay(type, sessionId, type === "permission.asked" ? properties.permission : undefined);
      } catch {
        // fail-open
      }
    },
  };
};
