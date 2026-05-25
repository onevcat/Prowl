import type { ActionId } from "./types";

export type KeyChord = string;

export const defaultShortcuts: Array<[ActionId, KeyChord]> = [
  ["palette.open", "Mod+K"],
  ["palette.close", "Escape"],
  ["performance.toggle", "Mod+Shift+P"],
  ["view.diff", "Mod+Shift+Y"],
  ["pane.new", "Mod+T"],
  ["pane.close", "Mod+W"],
  ["worktree.previous", "Mod+Control+ArrowLeft"],
  ["worktree.next", "Mod+Control+ArrowRight"],
  ["tab.previous", "Mod+Control+ArrowUp"],
  ["tab.next", "Mod+Control+ArrowDown"],
];

export const shortcuts = new Map<KeyChord, ActionId>(defaultShortcuts.map(([action, chord]) => [chord, action]));

export function normalizeKeyChord(event: KeyboardEvent): KeyChord {
  const parts: string[] = [];
  const isApple = /Mac|iPhone|iPad/.test(navigator.platform);
  const modPressed = isApple ? event.metaKey : event.ctrlKey;

  if (modPressed) {
    parts.push("Mod");
  }
  if (event.ctrlKey && (isApple || !modPressed)) {
    parts.push("Control");
  }
  if (event.altKey) {
    parts.push("Alt");
  }
  if (event.shiftKey) {
    parts.push("Shift");
  }

  parts.push(event.key.length === 1 ? event.key.toUpperCase() : event.key);
  return parts.join("+");
}

export function shortcutAliases(chord: KeyChord, platform = navigator.platform): KeyChord[] {
  const normalized = chord.trim();
  if (!normalized) {
    return [];
  }

  const aliases = [normalized];
  if (!/Mac|iPhone|iPad/.test(platform)) {
    const parts = normalized.split("+");
    if (parts.includes("Mod") && parts.includes("Control") && !parts.includes("Alt")) {
      aliases.push(parts.map((part) => (part === "Control" ? "Alt" : part)).join("+"));
    }
  }
  return aliases;
}

export function shouldHandleGlobalShortcut(event: Pick<KeyboardEvent, "defaultPrevented" | "target">): boolean {
  if (event.defaultPrevented) {
    return false;
  }
  return !isEditableShortcutTarget(event.target);
}

export function isTerminalShortcutTarget(target: EventTarget | null): boolean {
  if (!target || typeof (target as { closest?: unknown }).closest !== "function") {
    return false;
  }
  const element = target as unknown as { closest: (selector: string) => unknown };
  return Boolean(element.closest(".terminal"));
}

function isEditableShortcutTarget(target: EventTarget | null): boolean {
  if (!target || typeof (target as { closest?: unknown }).closest !== "function") {
    return false;
  }
  if (isTerminalShortcutTarget(target)) {
    return false;
  }
  const element = target as unknown as { closest: (selector: string) => unknown };
  return Boolean(element.closest("input, textarea, select, [contenteditable=''], [contenteditable='true']"));
}
