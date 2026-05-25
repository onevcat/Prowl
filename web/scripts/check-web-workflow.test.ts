import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const rootPackageJson = JSON.parse(readText("../package.json")) as {
  scripts?: Record<string, string>;
};
const webWorkflow = readText("../../.github/workflows/web.yml");

describe("web CI workflow", () => {
  test("runs the SvelteKit Vitest suite explicitly", () => {
    expect(rootPackageJson.scripts?.["test:web"]).toBe("bun run --filter @prowl/web test");
    expect(webWorkflow).toContain("bun run test:web");
  });
});

function readText(path: string): string {
  return readFileSync(new URL(path, import.meta.url), "utf8");
}
