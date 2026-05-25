export function nextPaletteIndex(current: number, resultCount: number, direction: 1 | -1): number {
  if (resultCount <= 0) {
    return 0;
  }
  return clampPaletteIndex(current + direction, resultCount);
}

export function clampPaletteIndex(current: number, resultCount: number): number {
  if (resultCount <= 0) {
    return 0;
  }
  return Math.min(Math.max(current, 0), resultCount - 1);
}
