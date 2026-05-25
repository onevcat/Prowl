import { describe, expect, test, vi } from "vitest";
import { RendererPool } from "./RendererPool";

describe("RendererPool", () => {
  test("keeps active renderer holders under the configured limit", () => {
    const now = vi.spyOn(performance, "now");
    now.mockReturnValueOnce(1).mockReturnValueOnce(2).mockReturnValueOnce(3);
    const pool = new RendererPool(2);

    expect(pool.acquire("pane-1")).toBe(true);
    expect(pool.acquire("pane-2")).toBe(true);
    expect(pool.acquire("pane-3")).toBe(true);

    expect(pool.activeCount).toBe(2);
    expect(pool.activeIds).toEqual(["pane-2", "pane-3"]);
    now.mockRestore();
  });

  test("releases panes that are no longer visible", () => {
    const pool = new RendererPool(8);
    pool.acquire("pane-1");
    pool.acquire("pane-2");

    pool.releaseMissing(new Set(["pane-2"]));

    expect(pool.activeIds).toEqual(["pane-2"]);
  });
});
