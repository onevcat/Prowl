import { describe, expect, test } from "vitest";
import { parseGitDiff } from "./model";
import type { DiffWorkerRequest, DiffWorkerResponse } from "./worker";
import { parseGitDiffInWorker } from "./worker";

const sampleDiff = `diff --git a/src/app.ts b/src/app.ts
index 1111111..2222222 100644
--- a/src/app.ts
+++ b/src/app.ts
@@ -1 +1,2 @@
-old
+new
+added`;

describe("diff worker bridge", () => {
  test("parses git diff through a worker", async () => {
    const files = await parseGitDiffInWorker(sampleDiff, () => new InlineDiffWorker() as unknown as Worker);

    expect(files).toHaveLength(1);
    expect(files[0]?.path).toBe("src/app.ts");
    expect(files[0]?.added).toBe(2);
    expect(files[0]?.removed).toBe(1);
  });
});

class InlineDiffWorker {
  onmessage: ((event: MessageEvent<DiffWorkerResponse>) => void) | null = null;
  onerror: ((event: ErrorEvent) => void) | null = null;

  postMessage(message: DiffWorkerRequest): void {
    queueMicrotask(() => {
      this.onmessage?.(
        new MessageEvent("message", {
          data: {
            id: message.id,
            files: parseGitDiff(message.diff),
          } satisfies DiffWorkerResponse,
        }),
      );
    });
  }

  terminate(): void {}
}
