import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findClientCspViolations } from "./check-client-csp";

describe("client CSP checks", () => {
  test("accepts the SvelteKit CSP required by WEB.md", () => {
    expect(findClientCspViolations(join(import.meta.dirname, "..", "apps", "web", "svelte.config.js"))).toEqual([]);
  });

  test("reports missing required directives and values", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-client-csp-check-"));
    const configPath = join(root, "svelte.config.js");
    mkdirSync(root, { recursive: true });
    writeFileSync(
      configPath,
      `export default {
        kit: {
          csp: {
            directives: {
              "default-src": ["'self'"],
              "script-src": ["'self'"],
              "connect-src": ["'self'"],
            },
          },
        },
      };`,
    );

    expect(findClientCspViolations(configPath)).toEqual([
      "- script-src missing 'wasm-unsafe-eval'",
      "- missing style-src",
      "- connect-src missing ws://127.0.0.1:*",
      "- connect-src missing wss:",
      "- missing img-src",
      "- missing worker-src",
      "- missing font-src",
      "- missing object-src",
      "- missing base-uri",
      "- missing frame-ancestors",
    ]);
  });
});
