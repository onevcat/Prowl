import { describe, expect, test } from "vitest";
import { type TerminalKeyEvent, encodeTerminalKey } from "./keyEncoding";

describe("encodeTerminalKey", () => {
  test("encodes printable characters and basic editing keys", () => {
    expect(encodeTerminalKey(key("a"))).toBe("a");
    expect(encodeTerminalKey(key("Enter"))).toBe("\r");
    expect(encodeTerminalKey(key("Backspace"))).toBe("\x7f");
    expect(encodeTerminalKey(key("Tab"))).toBe("\t");
  });

  test("encodes cursor and navigation keys as ANSI escape sequences", () => {
    expect(encodeTerminalKey(key("ArrowUp"))).toBe("\x1b[A");
    expect(encodeTerminalKey(key("ArrowDown"))).toBe("\x1b[B");
    expect(encodeTerminalKey(key("ArrowRight"))).toBe("\x1b[C");
    expect(encodeTerminalKey(key("ArrowLeft"))).toBe("\x1b[D");
    expect(encodeTerminalKey(key("Delete"))).toBe("\x1b[3~");
    expect(encodeTerminalKey(key("PageUp"))).toBe("\x1b[5~");
  });

  test("encodes common control keys for shells and terminal apps", () => {
    expect(encodeTerminalKey(key("c", { ctrlKey: true }))).toBe("\x03");
    expect(encodeTerminalKey(key("D", { ctrlKey: true }))).toBe("\x04");
    expect(encodeTerminalKey(key("l", { ctrlKey: true }))).toBe("\x0c");
    expect(encodeTerminalKey(key("[", { ctrlKey: true }))).toBe("\x1b");
  });

  test("uses escape prefixes for alt-modified terminal input", () => {
    expect(encodeTerminalKey(key("f", { altKey: true }))).toBe("\x1bf");
    expect(encodeTerminalKey(key("ArrowLeft", { altKey: true }))).toBe("\x1b\x1b[D");
  });

  test("leaves app-level and IME composition keys alone", () => {
    expect(encodeTerminalKey(key("k", { metaKey: true }))).toBeNull();
    expect(encodeTerminalKey(key("Process", { isComposing: true }))).toBeNull();
    expect(encodeTerminalKey(key("Shift"))).toBeNull();
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
