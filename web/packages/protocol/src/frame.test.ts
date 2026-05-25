import { describe, expect, test } from "bun:test";
import { decodeFrame, encodeJsonFrame, encodePtyFrame } from "./frame";
import { maxBinaryPayloadBytes, maxJsonPayloadBytes, protocolTags } from "./version";

describe("protocol frames", () => {
  test("round trips PTY frames", () => {
    const input = new Uint8Array([104, 105]);
    const decoded = decodeFrame(encodePtyFrame(42, input));

    expect(decoded.tag).toBe(protocolTags.pty);
    if (decoded.tag === protocolTags.pty) {
      expect(decoded.channelId).toBe(42);
      expect(Array.from(decoded.payload)).toEqual([104, 105]);
    }
  });

  test("round trips JSON frames", () => {
    const decoded = decodeFrame(encodeJsonFrame({ v: 1, type: "ping", id: "abc" }));

    expect(decoded.tag).toBe(protocolTags.json);
    if (decoded.tag === protocolTags.json) {
      expect(JSON.parse(decoded.payload)).toEqual({ v: 1, type: "ping", id: "abc" });
    }
  });

  test("rejects oversized decoded PTY frames", () => {
    const frame = new Uint8Array(5 + maxBinaryPayloadBytes + 1);
    const view = new DataView(frame.buffer);
    view.setUint8(0, protocolTags.pty);
    view.setUint32(1, 1, false);

    expect(() => decodeFrame(frame)).toThrow("PTY payload exceeds");
  });

  test("rejects oversized decoded JSON frames", () => {
    const frame = new Uint8Array(5 + maxJsonPayloadBytes + 1);
    const view = new DataView(frame.buffer);
    view.setUint8(0, protocolTags.json);
    view.setUint32(1, maxJsonPayloadBytes + 1, false);

    expect(() => decodeFrame(frame)).toThrow("JSON payload exceeds");
  });
});
