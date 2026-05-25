import { describe, expect, test } from "vitest";
import { clampPaletteIndex, nextPaletteIndex } from "./navigation";

describe("palette navigation", () => {
  test("keeps the top result selected when a query shrinks the result set", () => {
    expect(clampPaletteIndex(4, 1)).toBe(0);
  });

  test("clamps arrow navigation to the visible result bounds", () => {
    expect(nextPaletteIndex(0, 3, -1)).toBe(0);
    expect(nextPaletteIndex(2, 3, 1)).toBe(2);
    expect(nextPaletteIndex(1, 3, 1)).toBe(2);
  });

  test("uses zero as the stable empty-state index", () => {
    expect(clampPaletteIndex(9, 0)).toBe(0);
    expect(nextPaletteIndex(9, 0, 1)).toBe(0);
  });
});
