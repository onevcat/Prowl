import { describe, expect, test } from "vitest";
import { appendTerminalOutput, lastNonEmptyLine, terminalOutputSnapshot } from "./outputBuffer";

describe("terminal output buffer", () => {
  test("keeps terminal text separate from the last non-empty summary line", () => {
    const snapshot = appendTerminalOutput("first\n", "second\n\n");

    expect(snapshot.text).toBe("first\nsecond\n\n");
    expect(snapshot.lastOutputLine).toBe("second");
  });

  test("trims older terminal text while preserving the newest output", () => {
    const snapshot = terminalOutputSnapshot("abcdef", 4);

    expect(snapshot.text).toBe("cdef");
    expect(snapshot.lastOutputLine).toBe("cdef");
  });

  test("returns an empty summary for blank output", () => {
    expect(lastNonEmptyLine("\n  \r\n")).toBe("");
  });
});
