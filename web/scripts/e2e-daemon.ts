import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { startServer } from "../apps/daemon/src/server";

const token = "e2e-token";
const port = 7879;
const stateDir = resolve(".tmp/e2e");
const repoDir = resolve(".tmp/e2e-repo");

rmSync(stateDir, { recursive: true, force: true });
rmSync(repoDir, { recursive: true, force: true });
mkdirSync(stateDir, { recursive: true });
mkdirSync(repoDir, { recursive: true });
seedGitRepository(repoDir);
Bun.env.PROWL_REPO_ROOT = repoDir;

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

function seedGitRepository(path: string): void {
  runGit(path, "init");
  runGit(path, "config", "user.email", "prowl-e2e@example.test");
  runGit(path, "config", "user.name", "Prowl E2E");
  writeFileSync(join(path, "README.md"), "e2e baseline\n");
  runGit(path, "add", "README.md");
  runGit(path, "commit", "-m", "Seed e2e diff baseline");
  writeFileSync(join(path, "README.md"), "e2e changed\n");
}

function runGit(cwd: string, ...args: string[]): void {
  const result = Bun.spawnSync(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  if (result.exitCode !== 0) {
    const message = new TextDecoder().decode(result.stderr || result.stdout).trim();
    throw new Error(`git ${args.join(" ")} failed: ${message}`);
  }
}
