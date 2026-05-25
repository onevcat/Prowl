import { appendFileSync, mkdirSync } from "node:fs";
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

export function createLogger(options: { level?: LogLevel; directory?: string } = {}): Logger {
  const level = options.level ?? "info";
  const directory = options.directory ?? defaultLogDirectory();
  return {
    debug: (message) => writeLog(directory, level, "debug", message),
    info: (message) => writeLog(directory, level, "info", message),
    warn: (message) => writeLog(directory, level, "warn", message),
    error: (message) => writeLog(directory, level, "error", message),
  };
}

export function parseLogLevel(value: string | boolean | undefined): LogLevel {
  return value === "debug" || value === "info" || value === "warn" || value === "error" ? value : "info";
}

export function defaultLogDirectory(): string {
  return join(homedir(), ".prowl", "logs");
}

function writeLog(directory: string, configuredLevel: LogLevel, level: LogLevel, message: string): void {
  if (levelRank[level] < levelRank[configuredLevel]) {
    return;
  }
  mkdirSync(directory, { recursive: true });
  appendFileSync(logPath(directory, new Date()), `${line(new Date(), level, message)}\n`);
}

function logPath(directory: string, date: Date): string {
  return join(directory, `prowld-${date.toISOString().slice(0, 10)}.log`);
}

function line(date: Date, level: LogLevel, message: string): string {
  return `${date.toISOString()} ${level.toUpperCase().padEnd(5)} ${message.replaceAll(/\s+/g, " ")}`.slice(0, 80);
}
