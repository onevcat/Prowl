import type { PaletteItem } from "$lib/state/types";

export class CommandRegistry {
  #items = new Map<string, PaletteItem>();

  register(item: PaletteItem): void {
    this.#items.set(item.id, item);
  }

  list(): PaletteItem[] {
    return Array.from(this.#items.values());
  }
}
