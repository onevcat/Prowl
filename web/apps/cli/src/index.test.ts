import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../../daemon/src/server";
import { renderDaemonStatus } from "./commands/daemon";
import { renderVersion } from "./commands/version";
import { requestDaemon } from "./transport";

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

  test("renders daemon status", async () => {
    const text = await renderDaemonStatus();

    expect(text).toMatch(/running|stopped/);
    expect(text).toContain("prowld.sock");
  });

  test("captures send output in JSON mode", async () => {
    const token = "test-token";
    const home = mkdtempSync(join(tmpdir(), "prowl-cli-home-"));
    const prowlHome = join(home, ".prowl");
    mkdirSync(prowlHome, { recursive: true });
    writeFileSync(
      join(prowlHome, "config.json"),
      JSON.stringify({
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      }),
    );
    const socketPath = join(prowlHome, "prowld.sock");
    const server = startServer(
      {
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      },
      { socketPath, statePath: join(prowlHome, "state.sqlite"), spawnProcesses: true },
    );

    try {
      await Bun.sleep(50);
      const panes = await requestDaemon(
        {
          v: 1,
          type: "settings.get",
          id: crypto.randomUUID(),
          keys: ["panes"],
        },
        socketPath,
      );
      if (panes.type !== "settings.snapshot" || !Array.isArray(panes.settings.panes)) {
        throw new Error("Expected panes");
      }
      const pane = panes.settings.panes[0];
      const result = Bun.spawn(
        ["bun", "run", "src/index.ts", "--json", "send", pane.id, "printf capture-smoke", "--capture"],
        {
          cwd: new URL("..", import.meta.url).pathname,
          env: {
            ...Bun.env,
            PROWL_CONFIG_PATH: join(prowlHome, "config.json"),
            PROWL_SOCKET_PATH: socketPath,
          },
          stdout: "pipe",
          stderr: "pipe",
        },
      );
      const [exitCode, stdout, stderr] = await Promise.all([
        result.exited,
        new Response(result.stdout).text(),
        new Response(result.stderr).text(),
      ]);

      expect(exitCode).toBe(0);
      expect(stderr).toBe("");
      const output = JSON.parse(stdout);
      expect(output.output).toContain("capture-smoke");
    } finally {
      server.stop();
    }
  });
});
