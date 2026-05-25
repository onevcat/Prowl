import { lastNonEmptyLine } from "$lib/terminal/outputBuffer";

export function formatPaneNotificationBody(title: string, output: string): string {
  const line = lastNonEmptyLine(output);
  if (!line) {
    return title;
  }
  return line.startsWith(`${title}:`) ? line : `${title}: ${line}`;
}
