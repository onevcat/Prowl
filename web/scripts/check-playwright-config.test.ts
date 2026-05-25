import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const flakeNix = readText("../flake.nix");
const playwrightConfig = readText("../playwright.config.ts");

describe("Playwright Nix configuration", () => {
  test("declares only Chromium browsers in the dev shell", () => {
    expect(flakeNix).toContain("playwright-driver.browsers.override");
    expect(flakeNix).toContain("withChromium = true;");
    expect(flakeNix).toContain("withChromiumHeadlessShell = false;");
    expect(flakeNix).toContain("withFirefox = false;");
    expect(flakeNix).toContain("withWebkit = false;");
    expect(flakeNix).toContain("PLAYWRIGHT_BROWSERS_PATH");
    expect(flakeNix).toContain("PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1");
  });

  test("runs a single Chrome Playwright project through the Nix browser path", () => {
    expect(projectNames(playwrightConfig)).toEqual(["chrome"]);
    expect(playwrightConfig).toContain('...devices["Desktop Chrome"]');
    expect(playwrightConfig).toContain("process.env.PLAYWRIGHT_LAUNCH_OPTIONS_EXECUTABLE_PATH");
  });
});

function projectNames(source: string): string[] {
  return Array.from(source.matchAll(/name:\s*"([^"]+)"/g), (match) => match[1] ?? "");
}

function readText(path: string): string {
  return readFileSync(new URL(path, import.meta.url), "utf8");
}
