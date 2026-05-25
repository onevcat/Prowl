import { appendFileSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export type LogLevel = "debug" | "info" | "warn" | "error";

const levelRank: Record<LogLevel, number> = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
};

export type Logger = {
  debug: (message: string) => void;
  info: (message: string) => void;
  warn: (message: string) => void;
  error: (message: string) => void;
};

export function createLogger(options: { level?: LogLevel; directory?: string; now?: () => Date } = {}): Logger {
  const level = options.level ?? "info";
  const directory = options.directory ?? defaultLogDirectory();
  const now = options.now ?? (() => new Date());
  return {
    debug: (message) => writeLog(directory, level, "debug", message, now),
    info: (message) => writeLog(directory, level, "info", message, now),
    warn: (message) => writeLog(directory, level, "warn", message, now),
    error: (message) => writeLog(directory, level, "error", message, now),
  };
}

export function parseLogLevel(value: string | boolean | undefined): LogLevel {
  return value === "debug" || value === "info" || value === "warn" || value === "error" ? value : "info";
}

export function defaultLogDirectory(): string {
  return join(homedir(), ".prowl", "logs");
}

function writeLog(
  directory: string,
  configuredLevel: LogLevel,
  level: LogLevel,
  message: string,
  now: () => Date,
): void {
  if (levelRank[level] < levelRank[configuredLevel]) {
    return;
  }
  const date = now();
  mkdirSync(directory, { recursive: true });
  appendFileSync(logPath(directory, date), `${line(date, level, message)}\n`);
  pruneOldLogs(directory, date);
}

function logPath(directory: string, date: Date): string {
  return join(directory, `prowld-${date.toISOString().slice(0, 10)}.log`);
}

function line(date: Date, level: LogLevel, message: string): string {
  return `${date.toISOString()} ${level.toUpperCase().padEnd(5)} ${message.replaceAll(/\s+/g, " ")}`.slice(0, 80);
}

function pruneOldLogs(directory: string, now: Date): void {
  const cutoff = new Date(now);
  cutoff.setUTCDate(cutoff.getUTCDate() - 6);
  const cutoffName = logFileDate(cutoff);
  for (const entry of readdirSync(directory)) {
    const match = /^prowld-(\d{4}-\d{2}-\d{2})\.log$/.exec(entry);
    if (match?.[1] && match[1] < cutoffName) {
      rmSync(join(directory, entry), { force: true });
    }
  }
}

function logFileDate(date: Date): string {
  return date.toISOString().slice(0, 10);
}
