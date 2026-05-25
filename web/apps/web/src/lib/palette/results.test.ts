import type { PaletteItem } from "$lib/state/types";
import { describe, expect, test } from "vitest";
import { filterPaletteItems } from "./results";

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

  test("uses fzf matching across titles, subtitles, and sections", () => {
    expect(filterPaletteItems(items, "term pres").map((result) => result.id)).toEqual(["settings:appearance"]);
    expect(filterPaletteItems(items, "repos").map((result) => result.id)[0]).toBe("repo:prowl");
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
