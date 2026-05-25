export type DiffLineKind = "meta" | "context" | "added" | "removed";

export type DiffInlineSegment = {
  text: string;
  changed: boolean;
};

export type DiffLine = {
  kind: DiffLineKind;
  text: string;
  oldLine: number | null;
  newLine: number | null;
  inlineSegments?: DiffInlineSegment[];
};

export type SplitDiffRow = {
  oldLine: DiffLine | null;
  newLine: DiffLine | null;
};

export type DiffFile = {
  path: string;
  lines: DiffLine[];
  added: number;
  removed: number;
};

type HunkCursor = {
  oldLine: number;
  newLine: number;
};

export function parseGitDiff(diff: string): DiffFile[] {
  const files: DiffFile[] = [];
  let current: DiffFile | null = null;
  let cursor: HunkCursor | null = null;

  for (const rawLine of diff.split("\n")) {
    if (rawLine.startsWith("diff --git ")) {
      current = {
        path: parseDiffPath(rawLine),
        lines: [makeLine("meta", rawLine, null, null)],
        added: 0,
        removed: 0,
      };
      files.push(current);
      cursor = null;
      continue;
    }

    if (!current) {
      continue;
    }

    if (rawLine.startsWith("@@")) {
      cursor = parseHunkCursor(rawLine);
      current.lines.push(makeLine("meta", rawLine, null, null));
      continue;
    }

    if (!cursor || rawLine.startsWith("index ") || rawLine.startsWith("---") || rawLine.startsWith("+++")) {
      current.lines.push(makeLine("meta", rawLine, null, null));
      continue;
    }

    if (rawLine.startsWith("+")) {
      current.lines.push(makeLine("added", rawLine, null, cursor.newLine));
      current.added += 1;
      cursor.newLine += 1;
      continue;
    }

    if (rawLine.startsWith("-")) {
      current.lines.push(makeLine("removed", rawLine, cursor.oldLine, null));
      current.removed += 1;
      cursor.oldLine += 1;
      continue;
    }

    current.lines.push(makeLine("context", rawLine, cursor.oldLine, cursor.newLine));
    cursor.oldLine += 1;
    cursor.newLine += 1;
  }

  return files;
}

export function splitDiffRows(lines: DiffLine[]): SplitDiffRow[] {
  const rows: SplitDiffRow[] = [];
  const pendingRemoved: DiffLine[] = [];

  for (const line of lines) {
    if (line.kind === "removed") {
      pendingRemoved.push(line);
      continue;
    }

    if (line.kind === "added") {
      rows.push({ oldLine: pendingRemoved.shift() ?? null, newLine: line });
      continue;
    }

    while (pendingRemoved.length > 0) {
      rows.push({ oldLine: pendingRemoved.shift() ?? null, newLine: null });
    }

    if (line.kind === "context") {
      rows.push({ oldLine: line, newLine: line });
    } else {
      rows.push({ oldLine: line, newLine: line });
    }
  }

  while (pendingRemoved.length > 0) {
    rows.push({ oldLine: pendingRemoved.shift() ?? null, newLine: null });
  }

  return rows;
}

function makeLine(kind: DiffLineKind, text: string, oldLine: number | null, newLine: number | null): DiffLine {
  return { kind, text, oldLine, newLine };
}

function parseDiffPath(line: string): string {
  return line.split(" b/")[1] ?? line.split(" ").at(-1)?.replace(/^b\//, "") ?? line;
}

function parseHunkCursor(line: string): HunkCursor {
  const match = line.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
  return {
    oldLine: Number(match?.[1] ?? 0),
    newLine: Number(match?.[2] ?? 0),
  };
}
