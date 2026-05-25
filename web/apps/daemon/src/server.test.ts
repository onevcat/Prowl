import { describe, expect, test } from "bun:test";
import { protocolVersion } from "@prowl/protocol";

describe("daemon scaffold", () => {
  test("exports protocol version", () => {
    expect(protocolVersion).toBe(1);
  });
});
