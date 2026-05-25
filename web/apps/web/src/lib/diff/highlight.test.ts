import { describe, expect, test } from "vitest";
import type { ShikiWorkerRequest, ShikiWorkerResponse } from "./highlight";
import { highlightDiffFilesInWorker } from "./highlight";
import { parseGitDiff } from "./model";

const sampleDiff = `diff --git a/src/app.ts b/src/app.ts
index 1111111..2222222 100644
--- a/src/app.ts
+++ b/src/app.ts
@@ -1 +1 @@
-const oldValue = 1;
+const newValue = 2;`;

describe("highlightDiffFilesInWorker", () => {
  test("returns highlighted lines by file path", async () => {
    const restoreWorker = installWorkerGlobal();
    const highlighted = await highlightDiffFilesInWorker(
      parseGitDiff(sampleDiff),
      () => new InlineShikiWorker() as unknown as Worker,
    );
    restoreWorker();

    expect(highlighted.get("src/app.ts")).toEqual(["<span>meta</span>", "<span>removed</span>", "<span>added</span>"]);
  });
});

class InlineShikiWorker {
  onmessage: ((event: MessageEvent<ShikiWorkerResponse>) => void) | null = null;
  onerror: ((event: ErrorEvent) => void) | null = null;

  postMessage(message: ShikiWorkerRequest): void {
    queueMicrotask(() => {
      this.onmessage?.(
        new MessageEvent("message", {
          data: {
            id: message.id,
            files: message.files.map((file) => ({
              path: file.path,
              lines: ["<span>meta</span>", "<span>removed</span>", "<span>added</span>"],
            })),
          } satisfies ShikiWorkerResponse,
        }),
      );
    });
  }

  terminate(): void {}
}

function installWorkerGlobal(): () => void {
  const previous = globalThis.Worker;
  Object.defineProperty(globalThis, "Worker", {
    configurable: true,
    value: class {},
  });
  return () => {
    Object.defineProperty(globalThis, "Worker", {
      configurable: true,
      value: previous,
    });
  };
}
