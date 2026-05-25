import { describe, expect, test } from "vitest";
import { visibleRange } from "./virtual";

describe("visibleRange", () => {
  test("returns an empty range for empty input", () => {
    expect(visibleRange(0, 100, 200, 20)).toEqual({ start: 0, end: 0, offsetTop: 0, offsetBottom: 0 });
  });

  test("includes overscan around the visible rows", () => {
    expect(visibleRange(100, 200, 100, 20, 2)).toEqual({
      start: 8,
      end: 17,
      offsetTop: 160,
      offsetBottom: 1_660,
    });
  });

  test("clamps at the document edges", () => {
    expect(visibleRange(12, 10_000, 100, 20, 3)).toEqual({
      start: 8,
      end: 12,
      offsetTop: 160,
      offsetBottom: 0,
    });
  });
});
