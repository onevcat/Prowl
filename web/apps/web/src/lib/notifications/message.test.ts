import { describe, expect, test } from "vitest";
import { formatPaneNotificationBody } from "./message";

describe("formatPaneNotificationBody", () => {
  test("includes the pane title and last non-empty output line", () => {
    expect(formatPaneNotificationBody("Shell", "first\nsecond\n\n")).toBe("Shell: second");
  });

  test("does not duplicate a daemon-provided title prefix", () => {
    expect(formatPaneNotificationBody("Shell", "Shell: complete")).toBe("Shell: complete");
  });

  test("falls back to the pane title when output is empty", () => {
    expect(formatPaneNotificationBody("Shell", "\n")).toBe("Shell");
  });
});
