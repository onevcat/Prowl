import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findPaletteSearchPackageViolations } from "./check-palette-search-package";

describe("palette fuzzy package checks", () => {
  test("accepts the fzf-for-js implementation published as npm:fzf", () => {
    const root = fixture({
      webDependencies: { fzf: "^0.5.2" },
      fzfRepository: "ajitid/fzf-for-js",
    });

    expect(findPaletteSearchPackageViolations(root)).toEqual([]);
  });

  test("rejects missing or incompatible fuzzy packages", () => {
    const root = fixture({
      webDependencies: { "fuse.js": "^7.0.0" },
      fzfRepository: "other/fzf",
    });

    expect(findPaletteSearchPackageViolations(root)).toEqual([
      "@prowl/web dependencies must include npm:fzf",
      "@prowl/web dependencies must not include fuse.js",
      "installed npm:fzf package must come from ajitid/fzf-for-js",
    ]);
  });
});

function fixture(options: { webDependencies: Record<string, string>; fzfRepository: string }): string {
  const root = mkdtempSync(join(tmpdir(), "prowl-palette-search-package-"));
  mkdirSync(join(root, "apps", "web", "node_modules", "fzf"), { recursive: true });
  writeJson(join(root, "apps", "web", "package.json"), {
    dependencies: options.webDependencies,
  });
  writeJson(join(root, "apps", "web", "node_modules", "fzf", "package.json"), {
    repository: options.fzfRepository,
  });
  return root;
}

function writeJson(path: string, value: unknown): void {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}
