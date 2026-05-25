import { describe, expect, test } from "bun:test";
import { encodePaneKey } from "./pane";

describe("CLI pane key encoding", () => {
  test("encodes named terminal keys", () => {
    expect(decode(encodePaneKey("Enter"))).toBe("\r");
    expect(decode(encodePaneKey("Tab"))).toBe("\t");
    expect(decode(encodePaneKey("Esc"))).toBe("\x1b");
    expect(decode(encodePaneKey("Backspace"))).toBe("\x7f");
    expect(decode(encodePaneKey("Delete"))).toBe("\x1b[3~");
  });

  test("encodes navigation keys for terminal apps", () => {
    expect(decode(encodePaneKey("Up"))).toBe("\x1b[A");
    expect(decode(encodePaneKey("Down"))).toBe("\x1b[B");
    expect(decode(encodePaneKey("Right"))).toBe("\x1b[C");
    expect(decode(encodePaneKey("Left"))).toBe("\x1b[D");
    expect(decode(encodePaneKey("Home"))).toBe("\x1b[H");
    expect(decode(encodePaneKey("End"))).toBe("\x1b[F");
    expect(decode(encodePaneKey("PageUp"))).toBe("\x1b[5~");
    expect(decode(encodePaneKey("PageDown"))).toBe("\x1b[6~");
  });

  test("encodes control chords accepted by shells", () => {
    expect(decode(encodePaneKey("C-c"))).toBe("\x03");
    expect(decode(encodePaneKey("Ctrl-d"))).toBe("\x04");
    expect(decode(encodePaneKey("Control-["))).toBe("\x1b");
    expect(decode(encodePaneKey("C-\\"))).toBe("\x1c");
    expect(decode(encodePaneKey("C-]"))).toBe("\x1d");
  });

  test("passes unknown keys through as literal input", () => {
    expect(decode(encodePaneKey("literal"))).toBe("literal");
  });
});

function decode(value: Uint8Array): string {
  return new TextDecoder().decode(value);
}
