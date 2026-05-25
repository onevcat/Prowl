import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";

type PackageJson = {
  dependencies?: Record<string, string>;
  devDependencies?: Record<string, string>;
};

const ignoredDirectories = new Set(["coverage", "dist", "node_modules"]);
const sourceExtensions = new Set([".ts", ".js"]);
const forbiddenPtyPackages = new Set(["bun-pty", "node-pty", "pty.js"]);

function main(): void {
  const root = process.cwd();
  const violations = [
    ...findForbiddenDaemonRuntimeDependencies(join(root, "apps", "daemon", "package.json")),
    ...findForbiddenDaemonRuntimeUses(join(root, "apps", "daemon", "src")),
    ...findBunTerminalApiViolations(join(root, "apps", "daemon", "src")),
  ];
  if (violations.length === 0) {
    process.stdout.write("Forbidden daemon runtime patterns: none\n");
    return;
  }
  throw new Error(
    [
      "Prowl Web daemon runtime constraints were violated. Use Bun Terminal API instead of node-pty-style PTY packages.",
      ...violations.map((violation) => `- ${violation}`),
    ].join("\n"),
  );
}

export function findForbiddenDaemonRuntimeDependencies(packageJsonPath: string): string[] {
  const packageJson = JSON.parse(readFileSync(packageJsonPath, "utf8")) as PackageJson;
  return [
    ...dependencyViolations(packageJson.dependencies ?? {}, packageJsonPath, "dependencies"),
    ...dependencyViolations(packageJson.devDependencies ?? {}, packageJsonPath, "devDependencies"),
  ].sort();
}

export function findForbiddenDaemonRuntimeUses(root: string): string[] {
  if (!existsSync(root)) {
    throw new Error(`Directory not found: ${root}`);
  }
  const matches: string[] = [];
  visit(root, root, matches);
  return matches.sort();
}

export function findBunTerminalApiViolations(root: string): string[] {
  if (!existsSync(root)) {
    throw new Error(`Directory not found: ${root}`);
  }
  const sources = collectSourceFiles(root).map((path) => readFileSync(path, "utf8"));
  const usesBunSpawn = sources.some((source) => /\bBun\.spawn\s*\(/.test(source));
  const usesTerminalOption = sources.some((source) => /\bterminal\s*:\s*\{/.test(source));
  return usesBunSpawn && usesTerminalOption ? [] : ["daemon source does not configure Bun.spawn terminal PTY"];
}

function dependencyViolations(
  dependencies: Record<string, string>,
  packageJsonPath: string,
  section: string,
): string[] {
  return Object.keys(dependencies)
    .filter((name) => forbiddenPtyPackages.has(name))
    .map((name) => `${packageJsonPath} ${section} includes ${name}`);
}

function visit(root: string, current: string, matches: string[]): void {
  for (const path of collectSourceFiles(current)) {
    const source = readFileSync(path, "utf8");
    for (const packageName of forbiddenPtyPackages) {
      if (forbiddenPackageUsePattern(packageName).test(source)) {
        matches.push(`${relative(root, path)} imports ${packageName}`);
      }
    }
  }
}

function collectSourceFiles(root: string): string[] {
  const files: string[] = [];
  collectSourceFilesInto(root, files);
  return files;
}

function collectSourceFilesInto(current: string, files: string[]): void {
  for (const entry of readdirSync(current, { withFileTypes: true })) {
    const path = join(current, entry.name);
    if (entry.isDirectory()) {
      if (!ignoredDirectories.has(entry.name)) {
        collectSourceFilesInto(path, files);
      }
      continue;
    }
    if (entry.isFile() && sourceExtensions.has(fileExtension(entry.name))) {
      files.push(path);
    }
  }
}

function forbiddenPackageUsePattern(packageName: string): RegExp {
  const escaped = escapeRegExp(packageName);
  return new RegExp(
    [
      `from\\s+["']${escaped}["']`,
      `import\\s+["']${escaped}["']`,
      `import\\(\\s*["']${escaped}["']\\s*\\)`,
      `require\\(\\s*["']${escaped}["']\\s*\\)`,
    ].join("|"),
  );
}

function fileExtension(name: string): string {
  const index = name.lastIndexOf(".");
  return index === -1 ? "" : name.slice(index);
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

if (import.meta.main) {
  main();
}
