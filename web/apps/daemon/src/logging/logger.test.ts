import { describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
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

  test("keeps only the most recent seven daily logs", () => {
    const directory = mkdtempSync(join(tmpdir(), "prowl-retained-logs-"));
    writeFileSync(join(directory, "prowld-2026-05-18.log"), "old\n");
    writeFileSync(join(directory, "prowld-2026-05-19.log"), "keep\n");
    writeFileSync(join(directory, "prowld-2026-05-20.log"), "keep\n");
    writeFileSync(join(directory, "notes.log"), "unrelated\n");
    const logger = createLogger({
      directory,
      now: () => new Date("2026-05-25T12:00:00.000Z"),
    });

    logger.info("rotating");

    expect(existsSync(join(directory, "prowld-2026-05-18.log"))).toBe(false);
    expect(existsSync(join(directory, "prowld-2026-05-19.log"))).toBe(true);
    expect(existsSync(join(directory, "prowld-2026-05-20.log"))).toBe(true);
    expect(existsSync(join(directory, "prowld-2026-05-25.log"))).toBe(true);
    expect(existsSync(join(directory, "notes.log"))).toBe(true);
  });
});

function todaysLogPath(directory: string): string {
  const path = join(directory, `prowld-${new Date().toISOString().slice(0, 10)}.log`);
  expect(existsSync(path)).toBe(true);
  return path;
}
