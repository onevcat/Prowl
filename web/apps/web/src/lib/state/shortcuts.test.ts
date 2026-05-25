import { describe, expect, test } from "vitest";
import { isTerminalShortcutTarget, shortcutAliases, shouldHandleGlobalShortcut } from "./shortcuts";

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

  test("keeps app-level shortcuts active inside terminal input widgets", () => {
    expect(shouldHandleGlobalShortcut(shortcutEvent({ target: terminalInputTarget() }))).toBe(true);
  });

  test("detects terminal shortcut targets separately from editable controls", () => {
    expect(isTerminalShortcutTarget(terminalInputTarget())).toBe(true);
    expect(isTerminalShortcutTarget(editableTarget())).toBe(false);
    expect(isTerminalShortcutTarget(null)).toBe(false);
  });
});

describe("shortcut aliases", () => {
  test("keeps native Mod+Control chords on Apple platforms", () => {
    expect(shortcutAliases("Mod+Control+ArrowDown", "MacIntel")).toEqual(["Mod+Control+ArrowDown"]);
  });

  test("maps native Mod+Control chords to triggerable non-Apple chords", () => {
    expect(shortcutAliases("Mod+Control+ArrowDown", "Linux x86_64")).toEqual([
      "Mod+Control+ArrowDown",
      "Mod+Alt+ArrowDown",
    ]);
  });
});

class ShortcutTarget extends EventTarget {
  constructor(
    private readonly editable: boolean,
    private readonly insideTerminal = false,
  ) {
    super();
  }

  closest(selector = ""): ShortcutTarget | null {
    if (selector === ".terminal") {
      return this.insideTerminal ? this : null;
    }
    return this.editable ? this : null;
  }
}

function editableTarget(): ShortcutTarget {
  return new ShortcutTarget(true);
}

function nonEditableTarget(): ShortcutTarget {
  return new ShortcutTarget(false);
}

function terminalInputTarget(): ShortcutTarget {
  return new ShortcutTarget(true, true);
}

function shortcutEvent(overrides: Partial<Pick<KeyboardEvent, "defaultPrevented" | "target">> = {}) {
  return {
    defaultPrevented: false,
    target: null,
    ...overrides,
  };
}
