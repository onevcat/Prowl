import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findForbiddenClientStorageUses } from "./check-client-storage";

describe("client storage checks", () => {
  test("rejects localStorage in the web client source", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-client-storage-check-"));
    mkdirSync(join(root, "lib", "state"), { recursive: true });
    writeFileSync(join(root, "lib", "state", "token.ts"), "localStorage.setItem('prowl:token', token);\n");

    expect(findForbiddenClientStorageUses(root)).toEqual(["lib/state/token.ts"]);
  });

  test("allows sessionStorage and IndexedDB-backed storage", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-client-storage-allowed-"));
    mkdirSync(join(root, "lib", "state"), { recursive: true });
    writeFileSync(
      join(root, "lib", "state", "AppState.svelte.ts"),
      "sessionStorage.setItem('prowl:token', token);\nawait set('prowl:ui.view', 'shelf');\n",
    );

    expect(findForbiddenClientStorageUses(root)).toEqual([]);
  });

  test("ignores generated and dependency directories", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-client-storage-ignore-"));
    mkdirSync(join(root, ".svelte-kit"), { recursive: true });
    mkdirSync(join(root, "node_modules", "package"), { recursive: true });
    writeFileSync(join(root, ".svelte-kit", "generated.ts"), "localStorage.clear();\n");
    writeFileSync(join(root, "node_modules", "package", "index.js"), "localStorage.clear();\n");

    expect(findForbiddenClientStorageUses(root)).toEqual([]);
  });
});
