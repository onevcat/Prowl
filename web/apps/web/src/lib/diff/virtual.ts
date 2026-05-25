export type VirtualRange = {
  start: number;
  end: number;
  offsetTop: number;
  offsetBottom: number;
};

export function visibleRange(
  total: number,
  scrollTop: number,
  viewportHeight: number,
  rowHeight: number,
  overscan = 8,
): VirtualRange {
  if (total <= 0 || rowHeight <= 0 || viewportHeight <= 0) {
    return { start: 0, end: 0, offsetTop: 0, offsetBottom: 0 };
  }

  const safeScrollTop = Math.max(0, scrollTop);
  const firstVisible = Math.min(total - 1, Math.floor(safeScrollTop / rowHeight));
  const visibleCount = Math.ceil(viewportHeight / rowHeight);
  const start = Math.max(0, firstVisible - overscan);
  const end = Math.min(total, firstVisible + visibleCount + overscan);

  return {
    start,
    end,
    offsetTop: start * rowHeight,
    offsetBottom: Math.max(0, (total - end) * rowHeight),
  };
}
