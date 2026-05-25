import type { PaletteItem } from "$lib/state/types";
import { describe, expect, test } from "vitest";
import {
  type FuzzyWorkerRequest,
  type FuzzyWorkerResponse,
  filterPaletteItems,
  filterPaletteItemsAsync,
  fuzzyWorkerThreshold,
} from "./results";

describe("palette results", () => {
  const items: PaletteItem[] = [
    item("repo:prowl", "Prowl", "Repos", "/home/bubu/Prowl"),
    item("settings:appearance", "Appearance", "Settings", "Theme and terminal presentation"),
    item("action:build", "Build Web", "Actions", "bun run build"),
    item("pane:server", "Daemon Shell", "Tabs", "prowld listening"),
  ];

  test("keeps original order for an empty query", () => {
    expect(filterPaletteItems(items, "").map((result) => result.id)).toEqual([
      "repo:prowl",
      "settings:appearance",
      "action:build",
      "pane:server",
    ]);
  });

  test("returns the full unfiltered list so the palette can virtualize long histories", () => {
    const manyItems = Array.from({ length: 75 }, (_, index) => item(`pane:${index}`, `Pane ${index}`, "Tabs", "shell"));

    expect(filterPaletteItems(manyItems, "")).toHaveLength(75);
  });

  test("uses fzf matching across titles, subtitles, and sections", () => {
    expect(filterPaletteItems(items, "term pres").map((result) => result.id)).toEqual(["settings:appearance"]);
    expect(filterPaletteItems(items, "repos").map((result) => result.id)[0]).toBe("repo:prowl");
  });

  test("uses a worker for large non-empty queries", async () => {
    const restoreWorker = installWorkerGlobal();
    const largeItems = Array.from({ length: fuzzyWorkerThreshold + 1 }, (_, index) =>
      item(`pane:${index}`, `Pane ${index}`, "Tabs", index === 42 ? "needle match" : "shell"),
    );
    let postedRequest: FuzzyWorkerRequest | null = null;
    const results = await filterPaletteItemsAsync(largeItems, "needle", () => {
      const worker = {
        onmessage: null as ((event: MessageEvent<FuzzyWorkerResponse>) => void) | null,
        onerror: null as ((event: ErrorEvent) => void) | null,
        postMessage(request: FuzzyWorkerRequest) {
          postedRequest = request;
          this.onmessage?.({
            data: { id: request.id, itemIds: ["pane:42"] },
          } as MessageEvent<FuzzyWorkerResponse>);
        },
        terminate() {},
      };
      return worker as Worker;
    });
    restoreWorker();

    expect(postedRequest).not.toBeNull();
    expect((postedRequest as unknown as FuzzyWorkerRequest).items.length).toBe(fuzzyWorkerThreshold + 1);
    expect(results.map((result) => result.id)).toEqual(["pane:42"]);
  });

  test("keeps small queries on the main thread", async () => {
    const restoreWorker = installWorkerGlobal();
    let workerCreated = false;
    const results = await filterPaletteItemsAsync(items, "repos", () => {
      workerCreated = true;
      throw new Error("worker should not be created");
    });
    restoreWorker();

    expect(workerCreated).toBe(false);
    expect(results.map((result) => result.id)[0]).toBe("repo:prowl");
  });
});

function item(
  id: string,
  title: string,
  section: Exclude<PaletteItem["section"], "Recent">,
  subtitle: string,
): PaletteItem {
  return {
    id,
    title,
    subtitle,
    section,
    invoke: () => {},
  };
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
