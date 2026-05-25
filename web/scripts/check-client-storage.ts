import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";

const ignoredDirectories = new Set([".svelte-kit", "build", "coverage", "node_modules", "test-results"]);
const sourceExtensions = new Set([".svelte", ".ts", ".js"]);

function main(): void {
  const webAppSource = join(process.cwd(), "apps", "web", "src");
  const violations = findForbiddenClientStorageUses(webAppSource);
  if (violations.length === 0) {
    process.stdout.write("Forbidden client storage uses: none\n");
    return;
  }
  throw new Error(
    [
      "Prowl Web must not use localStorage. Use sessionStorage for the live token and IndexedDB for UI state.",
      ...violations.map((violation) => `- ${violation}`),
    ].join("\n"),
  );
}

export function findForbiddenClientStorageUses(root: string): string[] {
  if (!existsSync(root)) {
    throw new Error(`Directory not found: ${root}`);
  }
  const matches: string[] = [];
  visit(root, root, matches);
  return matches.sort();
}

function visit(root: string, current: string, matches: string[]): void {
  for (const entry of readdirSync(current, { withFileTypes: true })) {
    const path = join(current, entry.name);
    if (entry.isDirectory()) {
      if (!ignoredDirectories.has(entry.name)) {
        visit(root, path, matches);
      }
      continue;
    }
    if (!entry.isFile() || !sourceExtensions.has(fileExtension(entry.name))) {
      continue;
    }
    const source = readFileSync(path, "utf8");
    if (/\blocalStorage\b/.test(source)) {
      matches.push(relative(root, path));
    }
  }
}

function fileExtension(name: string): string {
  const index = name.lastIndexOf(".");
  return index === -1 ? "" : name.slice(index);
}

if (import.meta.main) {
  main();
}
