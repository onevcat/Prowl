import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";

const ignoredDirectories = new Set([".svelte-kit", "build", "coverage", "node_modules", "test-results"]);
const sourceExtensions = new Set([".svelte", ".ts", ".js"]);
const forbiddenPatterns: Array<{ pattern: RegExp; label: string }> = [
  { pattern: /\bBun\.(?:spawn|spawnSync|file|write|serve|listen)\b/, label: "uses Bun host APIs" },
  { pattern: /\b(?:spawn|spawnSync|exec|execSync)\s*\(/, label: "spawns a process" },
  {
    pattern: /\b(?:readFile|readFileSync|writeFile|writeFileSync|readdir|readdirSync|stat|statSync)\s*\(/,
    label: "uses filesystem APIs",
  },
  {
    pattern:
      /\bgit\s+(?:diff|status|worktree|clone|checkout|branch)\b|["']git["']\s*,\s*\[?\s*["'](?:diff|status|worktree|clone|checkout|branch)["']/i,
    label: "runs git client-side",
  },
  { pattern: /from\s+["'](?:node:)?(?:fs|fs\/promises|child_process|path)["']/, label: "imports host-only modules" },
  {
    pattern: /import\s*\(\s*["'](?:node:)?(?:fs|fs\/promises|child_process|path)["']\s*\)/,
    label: "imports host-only modules",
  },
];

function main(): void {
  const webAppSource = join(process.cwd(), "apps", "web", "src");
  const violations = findClientBoundaryViolations(webAppSource);
  if (violations.length === 0) {
    process.stdout.write("Client host-boundary violations: none\n");
    return;
  }
  throw new Error(
    [
      "Prowl Web client must not perform host-side work. Keep process, filesystem, path resolution, and git operations in the daemon.",
      ...violations.map((violation) => `- ${violation}`),
    ].join("\n"),
  );
}

export function findClientBoundaryViolations(root: string): string[] {
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
    if (!entry.isFile() || isTestFile(entry.name) || !sourceExtensions.has(fileExtension(entry.name))) {
      continue;
    }
    const source = readFileSync(path, "utf8");
    for (const { pattern, label } of forbiddenPatterns) {
      if (pattern.test(source)) {
        matches.push(`${relative(root, path)} ${label}`);
      }
    }
  }
}

function fileExtension(name: string): string {
  const index = name.lastIndexOf(".");
  return index === -1 ? "" : name.slice(index);
}

function isTestFile(name: string): boolean {
  return /\.(?:test|spec)\.[cm]?[jt]s$/.test(name);
}

if (import.meta.main) {
  main();
}
