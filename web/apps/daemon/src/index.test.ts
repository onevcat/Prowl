import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appVersion } from "@prowl/protocol";

const daemonRoot = new URL("..", import.meta.url).pathname;

describe("prowld CLI", () => {
  test("prints help without creating a config file", async () => {
    const directory = await mkdtemp(join(tmpdir(), "prowld-help-"));
    const configPath = join(directory, "config.json");

    try {
      const result = Bun.spawnSync(["bun", "run", "src/index.ts", "--help"], {
        cwd: daemonRoot,
        env: {
          ...Bun.env,
          PROWL_CONFIG_PATH: configPath,
        },
        stdout: "pipe",
        stderr: "pipe",
      });

      expect(result.exitCode).toBe(0);
      expect(new TextDecoder().decode(result.stdout)).toContain("prowld --print-token");
      expect(new TextDecoder().decode(result.stderr)).toBe("");
      expect(existsSync(configPath)).toBe(false);
    } finally {
      await rm(directory, { force: true, recursive: true });
    }
  });

  test("prints version without creating a config file", async () => {
    const directory = await mkdtemp(join(tmpdir(), "prowld-version-"));
    const configPath = join(directory, "config.json");

    try {
      const result = Bun.spawnSync(["bun", "run", "src/index.ts", "--version"], {
        cwd: daemonRoot,
        env: {
          ...Bun.env,
          PROWL_CONFIG_PATH: configPath,
        },
        stdout: "pipe",
        stderr: "pipe",
      });

      expect(result.exitCode).toBe(0);
      expect(new TextDecoder().decode(result.stdout)).toBe(`prowld ${appVersion}\n`);
      expect(new TextDecoder().decode(result.stderr)).toBe("");
      expect(existsSync(configPath)).toBe(false);
    } finally {
      await rm(directory, { force: true, recursive: true });
    }
  });

  test("prints and rotates the configured bearer token", async () => {
    const directory = await mkdtemp(join(tmpdir(), "prowld-token-"));
    const configPath = join(directory, "config.json");
    mkdirSync(directory, { recursive: true });
    writeFileSync(
      configPath,
      `${JSON.stringify({
        port: 7878,
        bind: "127.0.0.1",
        token: "existing-token",
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      })}\n`,
    );

    try {
      const printResult = Bun.spawnSync(["bun", "run", "src/index.ts", "--print-token"], {
        cwd: daemonRoot,
        env: {
          ...Bun.env,
          PROWL_CONFIG_PATH: configPath,
        },
        stdout: "pipe",
        stderr: "pipe",
      });
      const rotateResult = Bun.spawnSync(["bun", "run", "src/index.ts", "--rotate-token"], {
        cwd: daemonRoot,
        env: {
          ...Bun.env,
          PROWL_CONFIG_PATH: configPath,
        },
        stdout: "pipe",
        stderr: "pipe",
      });
      const rotatedConfig = JSON.parse(readFileSync(configPath, "utf8")) as { token: string };

      expect(printResult.exitCode).toBe(0);
      expect(new TextDecoder().decode(printResult.stdout).trim()).toBe("existing-token");
      expect(new TextDecoder().decode(printResult.stderr)).toBe("");
      expect(rotateResult.exitCode).toBe(0);
      expect(new TextDecoder().decode(rotateResult.stdout).trim()).toMatch(/^[0-9a-f]{64}$/);
      expect(new TextDecoder().decode(rotateResult.stderr)).toBe("");
      expect(rotatedConfig.token).toBe(new TextDecoder().decode(rotateResult.stdout).trim());
      expect(rotatedConfig.token).not.toBe("existing-token");
    } finally {
      await rm(directory, { force: true, recursive: true });
    }
  });

  test("writes command-line allowed origins into generated config", async () => {
    const directory = await mkdtemp(join(tmpdir(), "prowld-allowed-origin-"));
    const configPath = join(directory, "config.json");

    try {
      const result = Bun.spawnSync(
        [
          "bun",
          "run",
          "src/index.ts",
          "--print-token",
          "--allowed-origin",
          "https://prowl.example.com",
          "--allowed-origin=https://backup.example.com,https://team.example.com",
        ],
        {
          cwd: daemonRoot,
          env: {
            ...Bun.env,
            PROWL_CONFIG_PATH: configPath,
          },
          stdout: "pipe",
          stderr: "pipe",
        },
      );
      const config = JSON.parse(readFileSync(configPath, "utf8")) as { allowedOrigins: string[] };

      expect(result.exitCode).toBe(0);
      expect(new TextDecoder().decode(result.stderr)).toBe("");
      expect(config.allowedOrigins).toEqual([
        "https://prowl.example.com",
        "https://backup.example.com",
        "https://team.example.com",
      ]);
    } finally {
      await rm(directory, { force: true, recursive: true });
    }
  });
});
