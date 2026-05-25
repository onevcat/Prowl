import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

type DependencyBudget = {
  packages: {
    baselineCount: number;
    maxNewPackages: number;
  };
  directRuntimeDependencies: {
    maxPerPackage: number;
  };
};

type PackageJson = {
  name?: string;
  workspaces?: string[];
  dependencies?: Record<string, string>;
};

const lockfilePath = "bun.lock";
const budgetPath = "budgets/dependency-count.json";

function main(): void {
  const root = process.cwd();
  const budget = readJson<DependencyBudget>(join(root, budgetPath));
  const packageCount = countLockedPackages(readFileSync(join(root, lockfilePath), "utf8"));
  const allowedCount = budget.packages.baselineCount + budget.packages.maxNewPackages;
  const runtimeCounts = countRuntimeDependenciesByPackage(root);

  process.stdout.write(
    [
      `Locked packages: ${packageCount}`,
      `Baseline: ${budget.packages.baselineCount}`,
      `Allowed: ${allowedCount} (${budget.packages.maxNewPackages} new package cap)`,
      `Runtime dependencies per package cap: ${budget.directRuntimeDependencies.maxPerPackage}`,
      ...runtimeCounts.map((entry) => `- ${entry.name}: ${entry.count}`),
    ].join("\n"),
  );
  process.stdout.write("\n");

  if (packageCount > allowedCount) {
    throw new Error(
      `Locked package count ${packageCount} exceeds dependency budget ${allowedCount}. Review the added dependency graph before updating ${budgetPath}.`,
    );
  }
  const overBudget = runtimeCounts.filter((entry) => entry.count > budget.directRuntimeDependencies.maxPerPackage);
  if (overBudget.length > 0) {
    throw new Error(
      `Runtime dependency count exceeds ${budget.directRuntimeDependencies.maxPerPackage}: ${overBudget
        .map((entry) => `${entry.name}=${entry.count}`)
        .join(", ")}.`,
    );
  }
}

export function countLockedPackages(lockfile: string): number {
  const packagesStart = lockfile.indexOf('  "packages": {');
  if (packagesStart === -1) {
    throw new Error("bun.lock is missing the packages section");
  }
  const packagesEnd = lockfile.indexOf("\n  }\n}", packagesStart);
  if (packagesEnd === -1) {
    throw new Error("bun.lock packages section is not terminated as expected");
  }
  const packagesBlock = lockfile.slice(packagesStart, packagesEnd);
  return [...packagesBlock.matchAll(/^ {4}".+": \[/gm)].length;
}

export function countRuntimeDependenciesByPackage(root: string): Array<{ name: string; count: number }> {
  const rootPackageJson = readJson<PackageJson>(join(root, "package.json"));
  return (rootPackageJson.workspaces ?? [])
    .flatMap((workspace) => workspacePackageJsonPaths(root, workspace))
    .map((path) => {
      const packageJson = readJson<PackageJson>(path);
      return {
        name: packageJson.name ?? path,
        count: Object.keys(packageJson.dependencies ?? {}).length,
      };
    })
    .sort((left, right) => left.name.localeCompare(right.name));
}

function workspacePackageJsonPaths(root: string, workspace: string): string[] {
  if (!workspace.endsWith("/*")) {
    const path = join(root, workspace, "package.json");
    return existsSync(path) ? [path] : [];
  }
  const directory = join(root, workspace.slice(0, -2));
  if (!existsSync(directory)) {
    return [];
  }
  return readdirSync(directory)
    .map((entry) => join(directory, entry))
    .filter((path) => statSync(path).isDirectory() && existsSync(join(path, "package.json")))
    .map((path) => join(path, "package.json"));
}

function readJson<T>(path: string): T {
  if (!existsSync(path)) {
    throw new Error(`Required file not found: ${path}`);
  }
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

if (import.meta.main) {
  main();
}
