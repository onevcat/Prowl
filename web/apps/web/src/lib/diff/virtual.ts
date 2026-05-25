import { Virtualizer } from "@tanstack/virtual-core";

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

  const virtualizer = new Virtualizer<HTMLElement, HTMLElement>({
    count: total,
    estimateSize: () => rowHeight,
    getScrollElement: () => null,
    initialOffset: Math.max(0, scrollTop),
    initialRect: { width: 0, height: viewportHeight },
    observeElementOffset: () => {},
    observeElementRect: () => {},
    overscan,
    scrollToFn: () => {},
  });
  const items = virtualizer.getVirtualItems();
  const first = items[0];
  const last = items.at(-1);
  if (!first || !last) {
    return { start: 0, end: 0, offsetTop: 0, offsetBottom: 0 };
  }

  return {
    start: first.index,
    end: last.index + 1,
    offsetTop: first.start,
    offsetBottom: Math.max(0, virtualizer.getTotalSize() - last.end),
  };
}
