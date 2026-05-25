import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { countLockedPackages, countRuntimeDependenciesByPackage } from "./check-dependency-budget";

describe("dependency budget checks", () => {
  test("counts locked packages from bun.lock", () => {
    const lockfile = `{
  "lockfileVersion": 1,
  "packages": {
    "alpha": ["alpha@1.0.0", "", {}, "sha512-alpha"],
    "beta": ["beta@1.0.0", "", {}, "sha512-beta"]
  }
}
`;

    expect(countLockedPackages(lockfile)).toBe(2);
  });

  test("counts direct runtime dependencies for every workspace package", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-dependency-budget-"));
    mkdirSync(join(root, "apps", "web"), { recursive: true });
    mkdirSync(join(root, "packages", "protocol"), { recursive: true });
    writeJson(join(root, "package.json"), {
      workspaces: ["apps/*", "packages/*"],
    });
    writeJson(join(root, "apps", "web", "package.json"), {
      name: "@prowl/web",
      dependencies: {
        "@prowl/protocol": "workspace:*",
        svelte: "^5.0.0",
      },
      devDependencies: {
        vite: "^6.0.0",
      },
    });
    writeJson(join(root, "packages", "protocol", "package.json"), {
      name: "@prowl/protocol",
    });

    expect(countRuntimeDependenciesByPackage(root)).toEqual([
      { name: "@prowl/protocol", count: 0 },
      { name: "@prowl/web", count: 2 },
    ]);
  });
});

function writeJson(path: string, value: unknown): void {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}
