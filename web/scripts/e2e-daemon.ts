import { mkdirSync, rmSync } from "node:fs";
import { resolve } from "node:path";
import { startServer } from "../apps/daemon/src/server";

const token = "e2e-token";
const port = 7879;
const stateDir = resolve(".tmp/e2e");

rmSync(stateDir, { recursive: true, force: true });
mkdirSync(stateDir, { recursive: true });

const server = startServer(
  {
    port,
    bind: "127.0.0.1",
    token,
    allowedOrigins: ["http://127.0.0.1:5174"],
    requireTLS: false,
  },
  {
    socketPath: false,
    statePath: resolve(stateDir, "state.sqlite"),
    spawnProcesses: true,
    debugEndpoints: true,
  },
);

process.stdout.write(`prowld e2e listening on ${server.url}\n`);

function stop(): void {
  server.stop();
  process.exit(0);
}

process.on("SIGINT", stop);
process.on("SIGTERM", stop);

await new Promise(() => {});
