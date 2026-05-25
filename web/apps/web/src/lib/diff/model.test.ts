import { describe, expect, test } from "vitest";
import { parseGitDiff, splitDiffRows } from "./model";

const sampleDiff = `diff --git a/src/app.ts b/src/app.ts
index 1111111..2222222 100644
--- a/src/app.ts
+++ b/src/app.ts
@@ -1,4 +1,5 @@
 import { run } from "./run";
-const title = "old";
+const title = "new";
+const enabled = true;
 run(title);
diff --git a/README.md b/README.md
index 3333333..4444444 100644
--- a/README.md
+++ b/README.md
@@ -1 +1 @@
-Before
+After`;

describe("diff model", () => {
  test("parses git diff files, stats, and line numbers", () => {
    const files = parseGitDiff(sampleDiff);

    expect(files).toHaveLength(2);
    expect(files[0]?.path).toBe("src/app.ts");
    expect(files[0]?.added).toBe(2);
    expect(files[0]?.removed).toBe(1);
    expect(files[0]?.lines.find((line) => line.kind === "removed")?.oldLine).toBe(2);
    expect(files[0]?.lines.find((line) => line.kind === "added")?.newLine).toBe(2);
    expect(files[1]?.path).toBe("README.md");
  });

  test("pairs adjacent removed and added lines for split rendering", () => {
    const [file] = parseGitDiff(sampleDiff);
    if (!file) {
      throw new Error("Expected parsed file");
    }

    const rows = splitDiffRows(file.lines);
    const changed = rows.find(
      (row) => row.oldLine?.text === '-const title = "old";' && row.newLine?.text === '+const title = "new";',
    );
    const addedOnly = rows.find((row) => row.oldLine === null && row.newLine?.text === "+const enabled = true;");

    expect(changed).toBeDefined();
    expect(addedOnly).toBeDefined();
  });
});
