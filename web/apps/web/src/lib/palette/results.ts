import type { PaletteItem } from "$lib/state/types";
import { Fzf } from "fzf";

export function filterPaletteItems(items: PaletteItem[], query: string): PaletteItem[] {
  const normalized = query.trim().toLowerCase();
  if (!normalized) {
    return items.slice(0, 50);
  }
  return new Fzf(items, {
    limit: 50,
    selector: (item) => `${item.title} ${item.subtitle} ${item.section}`,
  })
    .find(normalized)
    .map((entry) => entry.item);
}
