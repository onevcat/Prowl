import { describe, expect, test } from "bun:test";
import { renderVersion } from "./commands/version";

describe("prowl cli scaffold", () => {
  test("renders version", () => {
    expect(renderVersion()).toBe("prowl 0.0.0");
  });

  test("renders JSON output for machine consumers", () => {
    const result = Bun.spawnSync(["bun", "run", "src/index.ts", "--json", "version"], {
      cwd: new URL("..", import.meta.url).pathname,
      stdout: "pipe",
      stderr: "pipe",
    });

    expect(result.exitCode).toBe(0);
    expect(JSON.parse(new TextDecoder().decode(result.stdout))).toEqual({ name: "prowl", version: "0.0.0" });
  });
});
