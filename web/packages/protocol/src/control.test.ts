import { describe, expect, test } from "bun:test";
import { parseClientControlMessage } from "./control";
import { protocolVersion } from "./version";

describe("control message parsing", () => {
  test("accepts valid client control messages", () => {
    const message = parseClientControlMessage(
      JSON.stringify({
        v: 1,
        type: "hello",
        id: "request-1",
        token: "token",
        clientVersion: "0.0.0",
        protocolVersion,
      }),
    );

    expect(message.type).toBe("hello");
  });

  test("rejects invalid JSON and missing envelope fields", () => {
    expect(() => parseClientControlMessage("{")).toThrow("valid JSON");
    expect(() => parseClientControlMessage(JSON.stringify({ v: 1, type: "ping" }))).toThrow("id is required");
  });

  test("rejects messages with missing required payload fields", () => {
    expect(() => parseClientControlMessage(JSON.stringify({ v: 1, type: "pane.resize", id: "request-1" }))).toThrow(
      "paneId must be a string",
    );
  });

  test("rejects unknown control message types", () => {
    expect(() => parseClientControlMessage(JSON.stringify({ v: 1, type: "unknown", id: "request-1" }))).toThrow(
      "Unsupported control message type",
    );
  });
});
