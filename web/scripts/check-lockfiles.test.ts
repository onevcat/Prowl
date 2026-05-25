import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findForbiddenLockfiles } from "./check-lockfiles";

describe("non-Bun lockfile checks", () => {
  test("finds forbidden lockfiles below workspace packages", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-lockfile-check-"));
    mkdirSync(join(root, "apps", "web"), { recursive: true });
    mkdirSync(join(root, "packages", "protocol"), { recursive: true });
    writeFileSync(join(root, "apps", "web", "package-lock.json"), "{}");
    writeFileSync(join(root, "packages", "protocol", "yarn.lock"), "");

    expect(findForbiddenLockfiles(root)).toEqual(["apps/web/package-lock.json", "packages/protocol/yarn.lock"]);
  });

  test("ignores dependency and build output directories", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-lockfile-ignore-"));
    mkdirSync(join(root, "node_modules", "package"), { recursive: true });
    mkdirSync(join(root, "apps", "web", ".svelte-kit"), { recursive: true });
    writeFileSync(join(root, "node_modules", "package", "package-lock.json"), "{}");
    writeFileSync(join(root, "apps", "web", ".svelte-kit", "pnpm-lock.yaml"), "");

    expect(findForbiddenLockfiles(root)).toEqual([]);
  });
});
