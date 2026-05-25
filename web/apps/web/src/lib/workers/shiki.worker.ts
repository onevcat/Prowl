import type { ShikiWorkerRequest, ShikiWorkerResponse } from "$lib/diff/highlight";
import { shikiLanguageForPath } from "$lib/diff/language";
import type { DiffFile, DiffLine } from "$lib/diff/model";
import { codeToTokensBase } from "shiki";

const theme = "github-light";

self.onmessage = (event: MessageEvent<ShikiWorkerRequest>) => {
  void highlightFiles(event.data.files)
    .then((files) => {
      self.postMessage({ id: event.data.id, files } satisfies ShikiWorkerResponse);
    })
    .catch((error) => {
      self.postMessage({
        id: event.data.id,
        error: error instanceof Error ? error.message : String(error),
      } satisfies ShikiWorkerResponse);
    });
};

async function highlightFiles(files: DiffFile[]): Promise<NonNullable<ShikiWorkerResponse["files"]>> {
  return Promise.all(
    files.map(async (file) => ({
      path: file.path,
      lines: await highlightFile(file),
    })),
  );
}

async function highlightFile(file: DiffFile): Promise<string[]> {
  const highlightedLines = await codeToTokensBase(file.lines.map(syntaxText).join("\n"), {
    lang: shikiLanguageForPath(file.path),
    theme,
  });
  return file.lines.map(
    (line, index) => `${escapeHtml(diffPrefix(line))}${tokensToHtml(highlightedLines[index] ?? [])}`,
  );
}

function syntaxText(line: DiffLine): string {
  return line.kind === "added" || line.kind === "removed" || line.kind === "context" ? line.text.slice(1) : line.text;
}

function diffPrefix(line: DiffLine): string {
  return line.kind === "added" || line.kind === "removed" || line.kind === "context" ? line.text.slice(0, 1) : "";
}

function tokensToHtml(tokens: Array<{ content: string; color?: string; fontStyle?: number }>): string {
  return tokens
    .map((token) => {
      const style = tokenStyle(token);
      return style ? `<span style="${style}">${escapeHtml(token.content)}</span>` : escapeHtml(token.content);
    })
    .join("");
}

function tokenStyle(token: { color?: string; fontStyle?: number }): string {
  const styles: string[] = [];
  if (token.color) {
    styles.push(`color: ${token.color}`);
  }
  if (token.fontStyle && (token.fontStyle & 1) === 1) {
    styles.push("font-style: italic");
  }
  if (token.fontStyle && (token.fontStyle & 2) === 2) {
    styles.push("font-weight: 700");
  }
  if (token.fontStyle && (token.fontStyle & 4) === 4) {
    styles.push("text-decoration: underline");
  }
  return styles.join("; ");
}

function escapeHtml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
}
