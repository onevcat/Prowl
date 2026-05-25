import type { PaletteItem } from "$lib/state/types";

export function filterPaletteItems(items: PaletteItem[], query: string): PaletteItem[] {
  const normalized = query.trim().toLowerCase();
  if (!normalized) {
    return items.slice(0, 50);
  }
  return items
    .map((item) => ({
      item,
      score: scoreItem(item, normalized),
    }))
    .filter((entry) => entry.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, 50)
    .map((entry) => entry.item);
}

function scoreItem(item: PaletteItem, query: string): number {
  const haystack = `${item.title} ${item.subtitle} ${item.section}`.toLowerCase();
  if (haystack.includes(query)) {
    return query.length + 20;
  }
  let score = 0;
  let index = 0;
  for (const character of query) {
    const found = haystack.indexOf(character, index);
    if (found === -1) {
      return 0;
    }
    score += found === index ? 2 : 1;
    index = found + 1;
  }
  return score;
}
