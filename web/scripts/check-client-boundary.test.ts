import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findClientBoundaryViolations } from "./check-client-boundary";

describe("client host boundary checks", () => {
  test("rejects process, filesystem, git, and host module usage in web client source", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-client-boundary-check-"));
    mkdirSync(join(root, "lib"), { recursive: true });
    writeFileSync(
      join(root, "lib", "host.ts"),
      [
        'import { readFileSync } from "node:fs";',
        'import { spawnSync } from "node:child_process";',
        'Bun.spawn(["git", "status"]);',
        'spawnSync("git", ["diff"]);',
        "readFileSync('/tmp/config.json', 'utf8');",
      ].join("\n"),
    );

    expect(findClientBoundaryViolations(root)).toEqual([
      "lib/host.ts imports host-only modules",
      "lib/host.ts runs git client-side",
      "lib/host.ts spawns a process",
      "lib/host.ts uses Bun host APIs",
      "lib/host.ts uses filesystem APIs",
    ]);
  });

  test("allows safe browser-side work delegated through websocket clients", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-client-boundary-allowed-"));
    mkdirSync(join(root, "lib", "state"), { recursive: true });
    writeFileSync(
      join(root, "lib", "state", "AppState.svelte.ts"),
      "this.ws.request({ v: 1, type: 'worktree.diff', id, worktreeId });\n",
    );

    expect(findClientBoundaryViolations(root)).toEqual([]);
  });

  test("ignores tests, generated files, and dependency directories", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-client-boundary-ignore-"));
    mkdirSync(join(root, ".svelte-kit"), { recursive: true });
    mkdirSync(join(root, "lib"), { recursive: true });
    mkdirSync(join(root, "node_modules", "package"), { recursive: true });
    writeFileSync(join(root, ".svelte-kit", "generated.ts"), "Bun.spawn(['git']);\n");
    writeFileSync(join(root, "lib", "model.test.ts"), "`git diff --no-color`;\n");
    writeFileSync(join(root, "node_modules", "package", "index.js"), "Bun.spawn(['git']);\n");

    expect(findClientBoundaryViolations(root)).toEqual([]);
  });
});
