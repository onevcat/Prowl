const controlKeys: Record<string, string> = {
  "[": "\x1b",
  "\\": "\x1c",
  "]": "\x1d",
  "^": "\x1e",
  _: "\x1f",
  a: "\x01",
  b: "\x02",
  c: "\x03",
  d: "\x04",
  e: "\x05",
  f: "\x06",
  g: "\x07",
  h: "\x08",
  j: "\x0a",
  k: "\x0b",
  l: "\x0c",
  m: "\x0d",
  n: "\x0e",
  o: "\x0f",
  q: "\x11",
  r: "\x12",
  s: "\x13",
  u: "\x15",
  v: "\x16",
  x: "\x18",
  y: "\x19",
  z: "\x1a",
};

const specialKeys: Record<string, string> = {
  ArrowUp: "\x1b[A",
  ArrowDown: "\x1b[B",
  ArrowRight: "\x1b[C",
  ArrowLeft: "\x1b[D",
  Home: "\x1b[H",
  End: "\x1b[F",
  PageUp: "\x1b[5~",
  PageDown: "\x1b[6~",
  Insert: "\x1b[2~",
  Delete: "\x1b[3~",
  Escape: "\x1b",
  Tab: "\t",
  Enter: "\r",
  Backspace: "\x7f",
};

export type TerminalKeyEvent = Pick<KeyboardEvent, "altKey" | "ctrlKey" | "isComposing" | "key" | "metaKey">;

export function encodeTerminalKey(event: TerminalKeyEvent): string | null {
  if (event.isComposing || event.metaKey) {
    return null;
  }

  if (event.ctrlKey) {
    return controlKeys[event.key.toLowerCase()] ?? null;
  }

  const special = specialKeys[event.key];
  if (special) {
    return event.altKey ? `\x1b${special}` : special;
  }

  if (event.key.length !== 1) {
    return null;
  }

  return event.altKey ? `\x1b${event.key}` : event.key;
}
