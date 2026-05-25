import { parseGitDiff } from "$lib/diff/model";
import type { DiffWorkerRequest, DiffWorkerResponse } from "$lib/diff/worker";

self.onmessage = (event: MessageEvent<DiffWorkerRequest>) => {
  try {
    self.postMessage({
      id: event.data.id,
      files: parseGitDiff(event.data.diff),
    } satisfies DiffWorkerResponse);
  } catch (error) {
    self.postMessage({
      id: event.data.id,
      error: error instanceof Error ? error.message : String(error),
    } satisfies DiffWorkerResponse);
  }
};
