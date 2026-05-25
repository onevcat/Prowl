import { existsSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";

const forbiddenLockfiles = new Set(["package-lock.json", "pnpm-lock.yaml", "yarn.lock"]);
const ignoredDirectories = new Set([".git", ".svelte-kit", "build", "dist", "node_modules"]);

function main(): void {
  const root = process.cwd();
  const lockfiles = findForbiddenLockfiles(root);
  if (lockfiles.length === 0) {
    process.stdout.write("Non-Bun lockfiles: none\n");
    return;
  }
  throw new Error(
    [
      "Non-Bun lockfiles are not allowed. Remove these files and use bun.lock only:",
      ...lockfiles.map((path) => `- ${path}`),
    ].join("\n"),
  );
}

export function findForbiddenLockfiles(root: string): string[] {
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
    if (entry.isFile() && forbiddenLockfiles.has(entry.name)) {
      matches.push(relative(root, path));
    }
  }
}

if (import.meta.main) {
  main();
}
