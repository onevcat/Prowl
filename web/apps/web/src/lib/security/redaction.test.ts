import { describe, expect, test } from "vitest";
import { redactSensitiveText } from "./redaction";

describe("redactSensitiveText", () => {
  test("redacts query token values", () => {
    expect(redactSensitiveText(new Error("connect failed ws://127.0.0.1:7878/ws?token=secret&x=1"))).toBe(
      "connect failed ws://127.0.0.1:7878/ws?token=[redacted]&x=1",
    );
  });

  test("redacts bearer tokens", () => {
    expect(redactSensitiveText("Authorization: Bearer secret-token")).toBe("Authorization: Bearer [redacted]");
  });

  test("redacts auth cookies", () => {
    expect(redactSensitiveText("Cookie: prowl_session=secret; Path=/")).toBe(
      "Cookie: prowl_session=[redacted]; Path=/",
    );
  });

  test("formats non-error values without redaction matches", () => {
    expect(redactSensitiveText(404)).toBe("404");
  });
});
