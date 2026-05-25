import { describe, expect, test } from "bun:test";
import { defaultRequireTLS, isLoopbackBind, normalizeConfig } from "./config";

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
});
