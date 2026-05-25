import type { TerminalKeyEvent } from "$lib/terminal/keyEncoding";
import { describe, expect, test } from "vitest";
import { encodeBroadcastKey } from "./broadcast";

describe("encodeBroadcastKey", () => {
  test("broadcasts printable keys and enter as terminal input", () => {
    expect(encodeBroadcastKey(key("a"))).toBe("a");
    expect(encodeBroadcastKey(key("Enter"))).toBe("\r");
  });

  test("broadcasts control chords and navigation keys", () => {
    expect(encodeBroadcastKey(key("c", { ctrlKey: true }))).toBe("\x03");
    expect(encodeBroadcastKey(key("ArrowUp"))).toBe("\x1b[A");
  });

  test("leaves app shortcuts and composing input alone", () => {
    expect(encodeBroadcastKey(key("k", { metaKey: true }))).toBeNull();
    expect(encodeBroadcastKey(key("Process", { isComposing: true }))).toBeNull();
  });
});

function key(value: string, overrides: Partial<TerminalKeyEvent> = {}): TerminalKeyEvent {
  return {
    altKey: false,
    ctrlKey: false,
    isComposing: false,
    key: value,
    metaKey: false,
    ...overrides,
  };
}
