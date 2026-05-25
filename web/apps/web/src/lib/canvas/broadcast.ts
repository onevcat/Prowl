import { type TerminalKeyEvent, encodeTerminalKey } from "$lib/terminal/keyEncoding";

export function encodeBroadcastKey(event: TerminalKeyEvent): string | null {
  return encodeTerminalKey(event);
}
