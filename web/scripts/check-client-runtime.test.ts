import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findForbiddenClientRuntimeDependencies, findForbiddenClientRuntimeUses } from "./check-client-runtime";

describe("client runtime checks", () => {
  test("rejects requestIdleCallback in the web client source", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-client-runtime-check-"));
    mkdirSync(join(root, "lib"), { recursive: true });
    writeFileSync(join(root, "lib", "input.ts"), "requestIdleCallback(() => flushInput());\n");

    expect(findForbiddenClientRuntimeUses(root)).toEqual(["lib/input.ts uses requestIdleCallback"]);
  });

  test("ignores generated and dependency directories", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-client-runtime-ignore-"));
    mkdirSync(join(root, ".svelte-kit"), { recursive: true });
    mkdirSync(join(root, "node_modules", "package"), { recursive: true });
    writeFileSync(join(root, ".svelte-kit", "generated.ts"), "requestIdleCallback(() => undefined);\n");
    writeFileSync(join(root, "node_modules", "package", "index.js"), "requestIdleCallback(() => undefined);\n");

    expect(findForbiddenClientRuntimeUses(root)).toEqual([]);
  });

  test("rejects forbidden client runtime dependencies", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-client-runtime-deps-"));
    const packageJsonPath = join(root, "package.json");
    writeFileSync(
      packageJsonPath,
      JSON.stringify({
        dependencies: {
          "@sentry/browser": "^9.0.0",
          "posthog-js": "^1.0.0",
          svelte: "^5.0.0",
        },
      }),
    );

    expect(findForbiddenClientRuntimeDependencies(packageJsonPath)).toEqual([
      `${packageJsonPath} depends on @sentry/browser`,
      `${packageJsonPath} depends on posthog-js`,
    ]);
  });
});
