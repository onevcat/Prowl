import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

type PackageJson = {
  dependencies?: Record<string, string>;
  repository?: string | { url?: string };
};

const webPackagePath = join("apps", "web", "package.json");
const fzfPackagePath = join("apps", "web", "node_modules", "fzf", "package.json");

function main(): void {
  const root = process.cwd();
  const violations = findPaletteSearchPackageViolations(root);
  if (violations.length > 0) {
    throw new Error(
      [
        "Prowl Web command palette must use the fzf-for-js implementation published as the fzf package.",
        ...violations.map((violation) => `- ${violation}`),
      ].join("\n"),
    );
  }
  process.stdout.write("Command palette fuzzy package: fzf-for-js via npm:fzf\n");
}

export function findPaletteSearchPackageViolations(root: string): string[] {
  const webPackage = readJson<PackageJson>(join(root, webPackagePath));
  const dependencies = webPackage.dependencies ?? {};
  const violations: string[] = [];

  if (!dependencies.fzf) {
    violations.push("@prowl/web dependencies must include npm:fzf");
  }
  for (const forbidden of ["fuse.js", "fuzzysort", "fzf-for-js"]) {
    if (dependencies[forbidden]) {
      violations.push(`@prowl/web dependencies must not include ${forbidden}`);
    }
  }

  const fzfPackage = readOptionalJson<PackageJson>(join(root, fzfPackagePath));
  const repository = repositoryText(fzfPackage?.repository);
  if (!repository.includes("ajitid/fzf-for-js")) {
    violations.push("installed npm:fzf package must come from ajitid/fzf-for-js");
  }

  return violations;
}

function readOptionalJson<T>(path: string): T | null {
  return existsSync(path) ? readJson<T>(path) : null;
}

function readJson<T>(path: string): T {
  if (!existsSync(path)) {
    throw new Error(`Required file not found: ${path}`);
  }
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

function repositoryText(repository: PackageJson["repository"]): string {
  if (typeof repository === "string") {
    return repository;
  }
  return repository?.url ?? "";
}

if (import.meta.main) {
  main();
}
