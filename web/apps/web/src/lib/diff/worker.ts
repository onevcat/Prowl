import { type DiffFile, parseGitDiff } from "./model";

export type DiffWorkerRequest = {
  id: number;
  diff: string;
};

export type DiffWorkerResponse = {
  id: number;
  files?: DiffFile[];
  error?: string;
};

export type DiffWorkerFactory = () => Worker;

let nextRequestId = 1;

export function parseGitDiffInWorker(
  diff: string,
  createWorker: DiffWorkerFactory = createDiffWorker,
): Promise<DiffFile[]> {
  if (typeof Worker === "undefined") {
    return parseGitDiffWithoutWorker(diff);
  }

  const id = nextRequestId++;
  const worker = createWorker();
  return new Promise((resolve, reject) => {
    worker.onmessage = (event: MessageEvent<DiffWorkerResponse>) => {
      if (event.data.id !== id) {
        return;
      }
      worker.terminate();
      if (event.data.error) {
        reject(new Error(event.data.error));
        return;
      }
      resolve(event.data.files ?? []);
    };
    worker.onerror = (event) => {
      worker.terminate();
      reject(new Error(event.message || "Diff worker failed"));
    };
    worker.postMessage({ id, diff } satisfies DiffWorkerRequest);
  });
}

async function parseGitDiffWithoutWorker(diff: string): Promise<DiffFile[]> {
  const { annotateDiffFilesWithInlineChanges } = await import("./inline");
  return annotateDiffFilesWithInlineChanges(parseGitDiff(diff));
}

function createDiffWorker(): Worker {
  return new Worker(new URL("$lib/workers/diff.worker.ts", import.meta.url), { type: "module" });
}
