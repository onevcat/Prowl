import { describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { configPath, defaultRequireTLS, isLoopbackBind, loadConfigWithMetadata, normalizeConfig } from "./config";

describe("daemon config", () => {
  test("defaults TLS requirement to loopback safety", () => {
    expect(defaultRequireTLS("127.0.0.1")).toBe(false);
    expect(defaultRequireTLS("localhost")).toBe(false);
    expect(defaultRequireTLS("::1")).toBe(false);
    expect(defaultRequireTLS("0.0.0.0")).toBe(true);
    expect(defaultRequireTLS("192.168.1.10")).toBe(true);
  });

  test("recognizes loopback bind addresses", () => {
    expect(isLoopbackBind("127.0.0.1")).toBe(true);
    expect(isLoopbackBind("[::1]")).toBe(true);
    expect(isLoopbackBind("0.0.0.0")).toBe(false);
  });

  test("generates a 256-bit token when config token is missing or empty", () => {
    const generated = normalizeConfig({ token: "" });
    const overrideGenerated = normalizeConfig({ token: "saved-token" }, { token: "   " });

    expect(generated.token).toMatch(/^[0-9a-f]{64}$/);
    expect(overrideGenerated.token).toMatch(/^[0-9a-f]{64}$/);
  });

  test("requires TLS when a bind override exposes the daemon remotely", () => {
    const config = normalizeConfig(
      {
        port: 7878,
        bind: "127.0.0.1",
        token: "token",
        allowedOrigins: [],
        requireTLS: false,
      },
      { bind: "0.0.0.0" },
    );

    expect(config.requireTLS).toBe(true);
  });

  test("allows explicit TLS override for local network development", () => {
    const config = normalizeConfig(
      {
        port: 7878,
        bind: "127.0.0.1",
        token: "token",
        allowedOrigins: [],
        requireTLS: false,
      },
      { bind: "0.0.0.0", requireTLS: false },
    );

    expect(config.requireTLS).toBe(false);
  });

  test("reports when a config file is created for the first launch", async () => {
    const previousConfigPath = Bun.env.PROWL_CONFIG_PATH;
    const directory = await mkdtemp(join(tmpdir(), "prowld-config-"));
    const path = join(directory, "config.json");
    Bun.env.PROWL_CONFIG_PATH = path;

    try {
      const firstLoad = await loadConfigWithMetadata();
      const written = JSON.parse(await readFile(path, "utf8")) as { token: string };
      const secondLoad = await loadConfigWithMetadata();

      expect(configPath()).toBe(path);
      expect(firstLoad.created).toBe(true);
      expect(firstLoad.config.token).toMatch(/^[0-9a-f]{64}$/);
      expect(written.token).toBe(firstLoad.config.token);
      expect(secondLoad.created).toBe(false);
      expect(secondLoad.config.token).toBe(firstLoad.config.token);
    } finally {
      if (previousConfigPath === undefined) {
        Bun.env.PROWL_CONFIG_PATH = undefined;
      } else {
        Bun.env.PROWL_CONFIG_PATH = previousConfigPath;
      }
      await rm(directory, { force: true, recursive: true });
    }
  });
});
