export const maxTerminalBufferCharacters = 64 * 1024;

export type TerminalOutputSnapshot = {
  text: string;
  lastOutputLine: string;
};

export function appendTerminalOutput(
  currentText: string,
  chunk: string,
  maxCharacters = maxTerminalBufferCharacters,
): TerminalOutputSnapshot {
  return terminalOutputSnapshot(`${currentText}${chunk}`, maxCharacters);
}

export function terminalOutputSnapshot(
  text: string,
  maxCharacters = maxTerminalBufferCharacters,
): TerminalOutputSnapshot {
  const trimmedText = text.length > maxCharacters ? text.slice(text.length - maxCharacters) : text;
  return {
    text: trimmedText,
    lastOutputLine: lastNonEmptyLine(trimmedText),
  };
}

export function lastNonEmptyLine(text: string): string {
  return (
    text
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)
      .at(-1) ?? ""
  );
}
