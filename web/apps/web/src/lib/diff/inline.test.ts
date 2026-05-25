import { describe, expect, test } from "vitest";
import { annotateDiffFilesWithInlineChanges } from "./inline";
import { parseGitDiff } from "./model";

const sampleDiff = `diff --git a/src/app.ts b/src/app.ts
index 1111111..2222222 100644
--- a/src/app.ts
+++ b/src/app.ts
@@ -1 +1 @@
-const title = "old";
+const title = "new";`;

describe("inline diff annotations", () => {
  test("uses diff-match-patch for adjacent removed and added lines", () => {
    const [file] = annotateDiffFilesWithInlineChanges(parseGitDiff(sampleDiff));
    if (!file) {
      throw new Error("Expected parsed file");
    }

    const removed = file.lines.find((line) => line.text === '-const title = "old";');
    const added = file.lines.find((line) => line.text === '+const title = "new";');

    expect(removed?.inlineSegments).toEqual([
      { text: "-", changed: false },
      { text: 'const title = "', changed: false },
      { text: "old", changed: true },
      { text: '";', changed: false },
    ]);
    expect(added?.inlineSegments).toEqual([
      { text: "+", changed: false },
      { text: 'const title = "', changed: false },
      { text: "new", changed: true },
      { text: '";', changed: false },
    ]);
  });
});
