import type { FuzzyWorkerRequest, FuzzyWorkerResponse } from "$lib/palette/results";
import { runFuzzySearch } from "$lib/palette/results";

self.onmessage = (event: MessageEvent<FuzzyWorkerRequest>) => {
  try {
    const items = runFuzzySearch(event.data.items, event.data.query).map((item) => item.id);
    self.postMessage({ id: event.data.id, itemIds: items } satisfies FuzzyWorkerResponse);
  } catch (error) {
    self.postMessage({
      id: event.data.id,
      error: error instanceof Error ? error.message : String(error),
    } satisfies FuzzyWorkerResponse);
  }
};
