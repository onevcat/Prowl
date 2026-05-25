import { describe, expect, test } from "bun:test";
import { clientControlMessageTypes, daemonCapabilities, makeMessageId, parseClientControlMessage } from "./control";
import { protocolVersion } from "./version";

describe("control message parsing", () => {
  test("declares every v1 client control message in capability order", () => {
    expect(clientControlMessageTypes).toEqual([
      "hello",
      "pane.create",
      "pane.close",
      "pane.list",
      "pane.resize",
      "pane.attach",
      "pane.detach",
      "pane.status",
      "worktree.list",
      "worktree.create",
      "worktree.archive",
      "worktree.diff",
      "repo.list",
      "repo.add",
      "repo.remove",
      "action.list",
      "action.upsert",
      "action.delete",
      "action.run",
      "settings.get",
      "settings.set",
      "ping",
    ]);
    expect(daemonCapabilities).toEqual(clientControlMessageTypes.filter((type) => type !== "hello"));
  });

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

  test("accepts pane list requests without payload fields", () => {
    const message = parseClientControlMessage(
      JSON.stringify({
        v: 1,
        type: "pane.list",
        id: makeMessageId(),
      }),
    );

    expect(message.type).toBe("pane.list");
  });

  test("ignores unknown fields for forward compatibility", () => {
    const message = parseClientControlMessage(
      JSON.stringify({
        v: 1,
        type: "ping",
        id: makeMessageId(),
        futureField: "ignored",
      }),
    );

    expect(message.type).toBe("ping");
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

  test("rejects non-positive pane dimensions", () => {
    expect(() =>
      parseClientControlMessage(
        JSON.stringify({ v: 1, type: "pane.resize", id: makeMessageId(), paneId: "pane-1", cols: 0, rows: 32 }),
      ),
    ).toThrow("cols must be a positive integer");
    expect(() =>
      parseClientControlMessage(
        JSON.stringify({
          v: 1,
          type: "pane.create",
          id: makeMessageId(),
          worktreeId: "worktree-1",
          cols: 80,
          rows: -1,
        }),
      ),
    ).toThrow("rows must be a positive integer");
  });

  test("rejects unknown control message types", () => {
    expect(() => parseClientControlMessage(JSON.stringify({ v: 1, type: "unknown", id: makeMessageId() }))).toThrow(
      "Unsupported control message type",
    );
  });
});
