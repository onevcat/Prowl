import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";

type PackageJson = {
  dependencies?: Record<string, string>;
};

const ignoredDirectories = new Set([".svelte-kit", "build", "coverage", "node_modules", "test-results"]);
const sourceExtensions = new Set([".svelte", ".ts", ".js"]);
const forbiddenRuntimeDependencies = new Set([
  "@emotion/react",
  "@emotion/styled",
  "@sentry/browser",
  "posthog-js",
  "styled-components",
]);

function main(): void {
  const root = process.cwd();
  const violations = [
    ...findForbiddenClientRuntimeUses(join(root, "apps", "web", "src")),
    ...findForbiddenClientRuntimeDependencies(join(root, "apps", "web", "package.json")),
  ];
  if (violations.length === 0) {
    process.stdout.write("Forbidden client runtime patterns: none\n");
    return;
  }
  throw new Error(
    [
      "Prowl Web client runtime constraints were violated. Keep input paths synchronous, analytics out of v1, and styling CSS-based.",
      ...violations.map((violation) => `- ${violation}`),
    ].join("\n"),
  );
}

export function findForbiddenClientRuntimeUses(root: string): string[] {
  if (!existsSync(root)) {
    throw new Error(`Directory not found: ${root}`);
  }
  const matches: string[] = [];
  visit(root, root, matches);
  return matches.sort();
}

export function findForbiddenClientRuntimeDependencies(packageJsonPath: string): string[] {
  const packageJson = JSON.parse(readFileSync(packageJsonPath, "utf8")) as PackageJson;
  return Object.keys(packageJson.dependencies ?? {})
    .filter((name) => forbiddenRuntimeDependencies.has(name))
    .sort()
    .map((name) => `${packageJsonPath} depends on ${name}`);
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
    if (/\brequestIdleCallback\b/.test(source)) {
      matches.push(`${relative(root, path)} uses requestIdleCallback`);
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
