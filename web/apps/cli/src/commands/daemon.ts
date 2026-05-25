import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { makeMessageId } from "@prowl/protocol";
import { defaultSocketPath, hello, loadCLIConfig, requestDaemon } from "../transport";

export type DaemonStatus = {
  running: boolean;
  pid?: number;
  socketPath: string;
  message: string;
};

const daemonStartTimeoutMs = 3000;
const daemonStartPollIntervalMs = 50;

export async function daemonStatus(): Promise<DaemonStatus> {
  const socketPath = defaultSocketPath();
  const pid = readPid();
  try {
    const config = await loadCLIConfig();
    await hello(config.token, socketPath);
    await requestDaemon({ v: 1, type: "ping", id: makeMessageId() }, socketPath);
    return { running: true, pid, socketPath, message: "running" };
  } catch {
    return { running: false, pid, socketPath, message: "stopped" };
  }
}

export async function renderDaemonStatus(): Promise<string> {
  const status = await daemonStatus();
  return status.pid
    ? `${status.message}\tpid=${status.pid}\tsocket=${status.socketPath}`
    : `${status.message}\tsocket=${status.socketPath}`;
}

export async function daemonStart(): Promise<DaemonStatus> {
  const socketPath = defaultSocketPath();
  const current = await daemonStatus();
  if (current.running) {
    return { ...current, message: "already running" };
  }

  const child = Bun.spawn(daemonCommand(), {
    cwd: webRoot(),
    env: Bun.env,
    stdout: "ignore",
    stderr: "ignore",
    stdin: "ignore",
  });
  writeFileSync(defaultPidPath(), `${child.pid}\n`);
  child.unref();
  try {
    await waitForDaemonReady(child.pid);
  } catch (error) {
    try {
      process.kill(child.pid, "SIGTERM");
    } catch {
      // The child may have already exited while the readiness check was polling.
    }
    rmSync(defaultPidPath(), { force: true });
    throw error;
  }
  return { running: true, pid: child.pid, socketPath, message: "started" };
}

export async function renderDaemonStart(): Promise<string> {
  const status = await daemonStart();
  return `${status.message}\tpid=${status.pid ?? "unknown"}\tsocket=${status.socketPath}`;
}

export async function daemonStop(): Promise<DaemonStatus> {
  const socketPath = defaultSocketPath();
  const pid = readPid();
  if (!pid) {
    return { running: false, socketPath, message: "not running" };
  }
  try {
    process.kill(pid, "SIGTERM");
    await waitForDaemonStopped();
    return { running: false, pid, socketPath, message: "stopped" };
  } catch {
    rmSync(defaultPidPath(), { force: true });
    return { running: false, pid, socketPath, message: "stale pid removed" };
  }
}

export async function renderDaemonStop(): Promise<string> {
  const status = await daemonStop();
  return status.pid ? `${status.message}\tpid=${status.pid}` : status.message;
}

function readPid(): number | undefined {
  try {
    const value = Number(readFileSync(defaultPidPath(), "utf8").trim());
    return Number.isInteger(value) && value > 0 ? value : undefined;
  } catch {
    return undefined;
  }
}

function daemonCommand(): string[] {
  if (Bun.env.PROWL_DAEMON_BIN) {
    return [Bun.env.PROWL_DAEMON_BIN];
  }
  for (const binary of daemonBinaryCandidates(webRoot())) {
    if (existsSync(binary)) {
      return [binary];
    }
  }
  return ["bun", "run", "apps/daemon/src/index.ts"];
}

export function daemonBinaryCandidates(root: string): string[] {
  const platformBinary = platformDaemonBinaryName();
  const binDirectory = join(root, "dist", "bin");
  const executableDirectory = dirname(Bun.argv[0] ?? process.execPath);
  return [
    join(binDirectory, "prowld"),
    ...(platformBinary ? [join(binDirectory, platformBinary)] : []),
    join(executableDirectory, "prowld"),
    ...(platformBinary ? [join(executableDirectory, platformBinary)] : []),
  ];
}

function platformDaemonBinaryName(): string | null {
  if (process.platform === "darwin" && process.arch === "arm64") {
    return "prowld-darwin-arm64";
  }
  if (process.platform === "linux" && process.arch === "x64") {
    return "prowld-linux-x64";
  }
  return null;
}

async function waitForDaemonReady(pid: number): Promise<void> {
  const deadline = performance.now() + daemonStartTimeoutMs;
  while (performance.now() < deadline) {
    const status = await daemonStatus();
    if (status.running && status.pid === pid) {
      return;
    }
    await Bun.sleep(daemonStartPollIntervalMs);
  }
  throw new Error("Timed out waiting for daemon to start");
}

async function waitForDaemonStopped(): Promise<void> {
  const deadline = performance.now() + daemonStartTimeoutMs;
  while (performance.now() < deadline) {
    const status = await daemonStatus();
    if (!status.running) {
      rmSync(defaultPidPath(), { force: true });
      return;
    }
    await Bun.sleep(daemonStartPollIntervalMs);
  }
  throw new Error("Timed out waiting for daemon to stop");
}

function webRoot(): string {
  return resolve(dirname(new URL(import.meta.url).pathname), "../../../..");
}

function defaultPidPath(): string {
  return join(dirname(defaultSocketPath()), "prowld.pid");
}
