import type { ActionId } from "./types";

export type KeyChord = string;

export const shortcuts = new Map<KeyChord, ActionId>([
  ["Mod+K", "palette.open"],
  ["Escape", "palette.close"],
  ["Mod+T", "pane.new"],
  ["Mod+W", "pane.close"],
  ["Mod+Control+ArrowLeft", "worktree.previous"],
  ["Mod+Control+ArrowRight", "worktree.next"],
  ["Mod+Control+ArrowUp", "tab.previous"],
  ["Mod+Control+ArrowDown", "tab.next"],
]);

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
