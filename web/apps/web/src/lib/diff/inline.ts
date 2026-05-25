import DiffMatchPatch from "diff-match-patch";
import type { DiffFile, DiffInlineSegment, DiffLine } from "./model";

export function annotateDiffFilesWithInlineChanges(files: DiffFile[]): DiffFile[] {
  for (const file of files) {
    annotateInlineChanges(file.lines);
  }
  return files;
}

function annotateInlineChanges(lines: DiffLine[]): void {
  const removed: DiffLine[] = [];

  for (const line of lines) {
    if (line.kind === "removed") {
      removed.push(line);
      continue;
    }

    if (line.kind === "added") {
      const oldLine = removed.shift();
      if (oldLine) {
        annotateInlineChangePair(oldLine, line);
      }
      continue;
    }

    removed.length = 0;
  }
}

function annotateInlineChangePair(oldLine: DiffLine, newLine: DiffLine): void {
  const dmp = new DiffMatchPatch();
  const diffs = dmp.diff_main(stripDiffMarker(oldLine.text), stripDiffMarker(newLine.text));
  dmp.diff_cleanupSemantic(diffs);

  oldLine.inlineSegments = withDiffMarker(
    "-",
    diffs.flatMap(([operation, text]) => (operation === 1 ? [] : [{ text, changed: operation === -1 }])),
  );
  newLine.inlineSegments = withDiffMarker(
    "+",
    diffs.flatMap(([operation, text]) => (operation === -1 ? [] : [{ text, changed: operation === 1 }])),
  );
}

function withDiffMarker(marker: string, segments: DiffInlineSegment[]): DiffInlineSegment[] {
  return [{ text: marker, changed: false }, ...segments];
}

function stripDiffMarker(text: string): string {
  return text.slice(1);
}
