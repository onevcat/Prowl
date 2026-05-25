import { describe, expect, test } from "vitest";
import { shouldHandleGlobalShortcut } from "./shortcuts";

describe("global shortcut handling", () => {
  test("ignores events that a focused widget already handled", () => {
    expect(shouldHandleGlobalShortcut(shortcutEvent({ defaultPrevented: true }))).toBe(false);
  });

  test("ignores shortcuts while editing form fields", () => {
    for (const target of [editableTarget(), editableTarget(), editableTarget()]) {
      expect(shouldHandleGlobalShortcut(shortcutEvent({ target }))).toBe(false);
    }
  });

  test("ignores shortcuts inside contenteditable regions", () => {
    expect(shouldHandleGlobalShortcut(shortcutEvent({ target: editableTarget() }))).toBe(false);
  });

  test("keeps app-level shortcuts active for terminal containers", () => {
    expect(shouldHandleGlobalShortcut(shortcutEvent({ target: nonEditableTarget() }))).toBe(true);
  });
});

class ShortcutTarget extends EventTarget {
  constructor(private readonly editable: boolean) {
    super();
  }

  closest(): ShortcutTarget | null {
    return this.editable ? this : null;
  }
}

function editableTarget(): ShortcutTarget {
  return new ShortcutTarget(true);
}

function nonEditableTarget(): ShortcutTarget {
  return new ShortcutTarget(false);
}

function shortcutEvent(overrides: Partial<Pick<KeyboardEvent, "defaultPrevented" | "target">> = {}) {
  return {
    defaultPrevented: false,
    target: null,
    ...overrides,
  };
}
