import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findForbiddenDaemonRuntimeDependencies, findForbiddenDaemonRuntimeUses } from "./check-daemon-runtime";

describe("daemon runtime checks", () => {
  test("rejects node-pty-style daemon dependencies", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-daemon-runtime-deps-"));
    const packageJsonPath = join(root, "package.json");
    writeFileSync(
      packageJsonPath,
      JSON.stringify({
        dependencies: {
          "node-pty": "^1.0.0",
        },
        devDependencies: {
          "bun-pty": "^0.1.0",
          typescript: "^5.6.3",
        },
      }),
    );

    expect(findForbiddenDaemonRuntimeDependencies(packageJsonPath)).toEqual([
      `${packageJsonPath} dependencies includes node-pty`,
      `${packageJsonPath} devDependencies includes bun-pty`,
    ]);
  });

  test("rejects node-pty-style imports in daemon source", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-daemon-runtime-imports-"));
    mkdirSync(join(root, "pty"), { recursive: true });
    writeFileSync(join(root, "pty", "native.ts"), 'import * as pty from "node-pty";\n');
    writeFileSync(join(root, "side-effect.ts"), 'import "bun-pty";\n');
    writeFileSync(join(root, "legacy.js"), 'const pty = require("pty.js");\n');

    expect(findForbiddenDaemonRuntimeUses(root)).toEqual([
      "legacy.js imports pty.js",
      "pty/native.ts imports node-pty",
      "side-effect.ts imports bun-pty",
    ]);
  });

  test("ignores generated and dependency directories", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-daemon-runtime-ignore-"));
    mkdirSync(join(root, "dist"), { recursive: true });
    mkdirSync(join(root, "node_modules", "node-pty"), { recursive: true });
    writeFileSync(join(root, "dist", "index.js"), 'import "node-pty";\n');
    writeFileSync(join(root, "node_modules", "node-pty", "index.js"), 'import "node-pty";\n');

    expect(findForbiddenDaemonRuntimeUses(root)).toEqual([]);
  });
});
