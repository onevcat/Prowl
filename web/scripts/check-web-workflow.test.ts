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

  test("keeps the WEB.md CI regression gates wired into the workflow", () => {
    expect(rootPackageJson.scripts?.["check:deps"]).toContain("check-dependency-budget");
    expect(rootPackageJson.scripts?.["check:bundle"]).toBe("bun run scripts/check-bundle-size.ts");
    expect(rootPackageJson.scripts?.e2e).toBe("bun --bun playwright test");

    expect(workflowRuns()).toEqual(
      expect.arrayContaining([
        'nix develop ./web -c bash -lc "cd web && bun run check:deps"',
        'nix develop ./web -c bash -lc "cd web && bun run check:bundle"',
        'nix develop ./web -c bash -lc "cd web && bun run e2e"',
      ]),
    );
  });

  test("publishes compiled daemon and CLI binaries as required release artifacts", () => {
    expect(rootPackageJson.scripts?.["build:binaries"]).toBe("bun run scripts/build-binaries.ts");
    expect(workflowRuns()).toContain('nix develop ./web -c bash -lc "cd web && bun run build:binaries"');
    expect(webWorkflow).toContain("actions/upload-artifact");
    expect(webWorkflow).toContain("path: web/dist/bin/*");
    expect(webWorkflow).toContain("if-no-files-found: error");
  });
});

function readText(path: string): string {
  return readFileSync(new URL(path, import.meta.url), "utf8");
}

function workflowRuns(): string[] {
  return Array.from(webWorkflow.matchAll(/^\s*-\s+run:\s+(.+)$/gm), (match) => match[1] ?? "");
}
