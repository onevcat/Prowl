import type { PaletteItem } from "$lib/state/types";
import { Fzf } from "fzf";

export const fuzzyWorkerThreshold = 5_000;

export type SerializablePaletteItem = Pick<PaletteItem, "id" | "title" | "subtitle" | "section">;

export type FuzzyWorkerRequest = {
  id: number;
  query: string;
  items: SerializablePaletteItem[];
};

export type FuzzyWorkerResponse = {
  id: number;
  itemIds?: string[];
  error?: string;
};

export type FuzzyWorkerFactory = () => Worker;

let nextRequestId = 1;

export function filterPaletteItems(items: PaletteItem[], query: string): PaletteItem[] {
  const normalized = query.trim().toLowerCase();
  if (!normalized) {
    return items.slice(0, 50);
  }
  return runFuzzySearch(items, normalized);
}

export function filterPaletteItemsAsync(
  items: PaletteItem[],
  query: string,
  createWorker: FuzzyWorkerFactory = createFuzzyWorker,
): Promise<PaletteItem[]> {
  const normalized = query.trim().toLowerCase();
  if (!normalized || items.length <= fuzzyWorkerThreshold || typeof Worker === "undefined") {
    return Promise.resolve(filterPaletteItems(items, query));
  }

  const id = nextRequestId++;
  const worker = createWorker();
  return new Promise((resolve, reject) => {
    worker.onmessage = (event: MessageEvent<FuzzyWorkerResponse>) => {
      if (event.data.id !== id) {
        return;
      }
      worker.terminate();
      if (event.data.error) {
        reject(new Error(event.data.error));
        return;
      }
      const itemById = new Map(items.map((item) => [item.id, item]));
      resolve((event.data.itemIds ?? []).flatMap((itemId) => itemById.get(itemId) ?? []));
    };
    worker.onerror = (event) => {
      worker.terminate();
      reject(new Error(event.message || "Fuzzy worker failed"));
    };
    worker.postMessage({
      id,
      query: normalized,
      items: items.map(({ id: itemId, title, subtitle, section }) => ({ id: itemId, title, subtitle, section })),
    } satisfies FuzzyWorkerRequest);
  });
}

export function runFuzzySearch<T extends SerializablePaletteItem>(items: T[], normalizedQuery: string): T[] {
  const itemById = new Map(items.map((item) => [item.id, item]));
  const searchableItems: SerializablePaletteItem[] = items;
  return new Fzf(searchableItems, {
    limit: 50,
    selector: (item: SerializablePaletteItem) => `${item.title} ${item.subtitle} ${item.section}`,
  })
    .find(normalizedQuery)
    .flatMap((entry) => itemById.get(entry.item.id) ?? []);
}

function createFuzzyWorker(): Worker {
  return new Worker(new URL("$lib/workers/fuzzy.worker.ts", import.meta.url), { type: "module" });
}
