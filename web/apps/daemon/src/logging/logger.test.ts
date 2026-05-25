import { describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createLogger, parseLogLevel } from "./logger";

describe("daemon logger", () => {
  test("writes info logs and filters debug by default", () => {
    const directory = mkdtempSync(join(tmpdir(), "prowl-logs-"));
    const logger = createLogger({ directory });

    logger.debug("hidden");
    logger.info("daemon started");

    const logPath = todaysLogPath(directory);
    const text = readFileSync(logPath, "utf8");
    expect(text).toContain("INFO");
    expect(text).toContain("daemon started");
    expect(text).not.toContain("hidden");
  });

  test("supports debug level and line length limit", () => {
    const directory = mkdtempSync(join(tmpdir(), "prowl-debug-logs-"));
    const logger = createLogger({ directory, level: "debug" });

    logger.debug("x".repeat(120));

    const line = readFileSync(todaysLogPath(directory), "utf8").trimEnd();
    expect(line).toContain("DEBUG");
    expect(line.length).toBeLessThanOrEqual(80);
  });

  test("parses log levels conservatively", () => {
    expect(parseLogLevel("debug")).toBe("debug");
    expect(parseLogLevel("warn")).toBe("warn");
    expect(parseLogLevel(true)).toBe("info");
    expect(parseLogLevel("verbose")).toBe("info");
  });
});

function todaysLogPath(directory: string): string {
  const path = join(directory, `prowld-${new Date().toISOString().slice(0, 10)}.log`);
  expect(existsSync(path)).toBe(true);
  return path;
}
