import { describe, expect, test } from "vitest";
import { detectAgentTaskStatus, inferAgentTaskStatus } from "./detectAgent";

describe("agent task status detection", () => {
  test("returns null when output has no clear task-state signal", () => {
    expect(inferAgentTaskStatus("building package list\ninstalling dependency\n")).toBeNull();
  });

  test("detects running, done, and failed signals from output tail", () => {
    expect(inferAgentTaskStatus("Thinking about the next edit")).toBe("running");
    expect(inferAgentTaskStatus("tokens used: 1234")).toBe("done");
    expect(inferAgentTaskStatus("command failed with exit code 1")).toBe("failed");
  });

  test("treats prompt-ready output as done after earlier running output", () => {
    expect(inferAgentTaskStatus("Thinking about the next edit\ntokens used: 1234")).toBe("done");
  });

  test("keeps idle fallback for callers that need a concrete status", () => {
    expect(detectAgentTaskStatus("plain output")).toBe("idle");
  });
});
