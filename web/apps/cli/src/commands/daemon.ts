import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { makeMessageId } from "@prowl/protocol";
import { hello, loadCLIConfig, requestDaemon } from "../transport";

export type DaemonStatus = {
  running: boolean;
  pid?: number;
  socketPath: string;
  message: string;
};

const socketPath = join(homedir(), ".prowl", "prowld.sock");
const pidPath = join(homedir(), ".prowl", "prowld.pid");

export async function daemonStatus(): Promise<DaemonStatus> {
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
  const current = await daemonStatus();
  if (current.running) {
    return { ...current, message: "already running" };
  }

  const child = Bun.spawn(daemonCommand(), {
    cwd: webRoot(),
    stdout: "ignore",
    stderr: "ignore",
    stdin: "ignore",
  });
  writeFileSync(pidPath, `${child.pid}\n`);
  child.unref();
  return { running: true, pid: child.pid, socketPath, message: "started" };
}

export async function renderDaemonStart(): Promise<string> {
  const status = await daemonStart();
  return `${status.message}\tpid=${status.pid ?? "unknown"}\tsocket=${status.socketPath}`;
}

export async function daemonStop(): Promise<DaemonStatus> {
  const pid = readPid();
  if (!pid) {
    return { running: false, socketPath, message: "not running" };
  }
  try {
    process.kill(pid, "SIGTERM");
    rmSync(pidPath, { force: true });
    return { running: false, pid, socketPath, message: "stopped" };
  } catch {
    rmSync(pidPath, { force: true });
    return { running: false, pid, socketPath, message: "stale pid removed" };
  }
}

export async function renderDaemonStop(): Promise<string> {
  const status = await daemonStop();
  return status.pid ? `${status.message}\tpid=${status.pid}` : status.message;
}

function readPid(): number | undefined {
  try {
    const value = Number(readFileSync(pidPath, "utf8").trim());
    return Number.isInteger(value) && value > 0 ? value : undefined;
  } catch {
    return undefined;
  }
}

function daemonCommand(): string[] {
  if (Bun.env.PROWL_DAEMON_BIN) {
    return [Bun.env.PROWL_DAEMON_BIN];
  }
  const binary = join(webRoot(), "dist", "bin", "prowld");
  if (existsSync(binary)) {
    return [binary];
  }
  return ["bun", "run", "apps/daemon/src/index.ts"];
}

function webRoot(): string {
  return resolve(dirname(new URL(import.meta.url).pathname), "../../../..");
}
