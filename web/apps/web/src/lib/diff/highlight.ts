import type { DiffFile } from "./model";

export type HighlightedDiffFile = {
  path: string;
  lines: string[];
};

export type ShikiWorkerRequest = {
  id: number;
  files: DiffFile[];
};

export type ShikiWorkerResponse = {
  id: number;
  files?: HighlightedDiffFile[];
  error?: string;
};

export type ShikiWorkerFactory = () => Worker;

let nextRequestId = 1;

export function highlightDiffFilesInWorker(
  files: DiffFile[],
  createWorker: ShikiWorkerFactory = createShikiWorker,
): Promise<Map<string, string[]>> {
  if (files.length === 0 || typeof Worker === "undefined") {
    return Promise.resolve(new Map());
  }

  const id = nextRequestId++;
  const worker = createWorker();
  return new Promise((resolve, reject) => {
    worker.onmessage = (event: MessageEvent<ShikiWorkerResponse>) => {
      if (event.data.id !== id) {
        return;
      }
      worker.terminate();
      if (event.data.error) {
        reject(new Error(event.data.error));
        return;
      }
      resolve(new Map((event.data.files ?? []).map((file) => [file.path, file.lines])));
    };
    worker.onerror = (event) => {
      worker.terminate();
      reject(new Error(event.message || "Shiki worker failed"));
    };
    worker.postMessage({ id, files } satisfies ShikiWorkerRequest);
  });
}

function createShikiWorker(): Worker {
  return new Worker(new URL("$lib/workers/shiki.worker.ts", import.meta.url), { type: "module" });
}
