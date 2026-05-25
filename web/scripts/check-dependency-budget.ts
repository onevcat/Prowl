import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

type DependencyBudget = {
  packages: {
    baselineCount: number;
    maxNewPackages: number;
  };
};

const lockfilePath = "bun.lock";
const budgetPath = "budgets/dependency-count.json";

function main(): void {
  const root = process.cwd();
  const budget = readJson<DependencyBudget>(join(root, budgetPath));
  const packageCount = countLockedPackages(readFileSync(join(root, lockfilePath), "utf8"));
  const allowedCount = budget.packages.baselineCount + budget.packages.maxNewPackages;

  process.stdout.write(
    [
      `Locked packages: ${packageCount}`,
      `Baseline: ${budget.packages.baselineCount}`,
      `Allowed: ${allowedCount} (${budget.packages.maxNewPackages} new package cap)`,
    ].join("\n"),
  );
  process.stdout.write("\n");

  if (packageCount > allowedCount) {
    throw new Error(
      `Locked package count ${packageCount} exceeds dependency budget ${allowedCount}. Review the added dependency graph before updating ${budgetPath}.`,
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

function readJson<T>(path: string): T {
  if (!existsSync(path)) {
    throw new Error(`Required file not found: ${path}`);
  }
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

if (import.meta.main) {
  main();
}
