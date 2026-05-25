import { describe, expect, test } from "bun:test";
import { makeMessageId, parseClientControlMessage } from "./control";
import { protocolVersion } from "./version";

describe("control message parsing", () => {
  test("accepts valid client control messages", () => {
    const message = parseClientControlMessage(
      JSON.stringify({
        v: 1,
        type: "hello",
        id: makeMessageId(),
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
    expect(() => parseClientControlMessage(JSON.stringify({ v: 1, type: "ping", id: "request-1" }))).toThrow(
      "id must be a UUID",
    );
  });

  test("rejects messages with missing required payload fields", () => {
    expect(() => parseClientControlMessage(JSON.stringify({ v: 1, type: "pane.resize", id: makeMessageId() }))).toThrow(
      "paneId must be a string",
    );
  });

  test("rejects unknown control message types", () => {
    expect(() => parseClientControlMessage(JSON.stringify({ v: 1, type: "unknown", id: makeMessageId() }))).toThrow(
      "Unsupported control message type",
    );
  });
});
