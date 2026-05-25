import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { makeMessageId, protocolVersion } from "@prowl/protocol";
import { handleControl } from "./server";
import { InMemoryState } from "./state/InMemoryState";

describe("daemon scaffold", () => {
  test("exports protocol version", () => {
    expect(protocolVersion).toBe(1);
  });

  test("validates repository paths before adding them", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-server-test-"));
    const state = new InMemoryState(root, { statePath: ":memory:", spawnProcesses: false });
    const config = {
      port: 0,
      bind: "127.0.0.1",
      token: "test-token",
      allowedOrigins: ["http://127.0.0.1:5173"],
      requireTLS: false,
    };

    const missing = handleControl(
      {
        v: 1,
        type: "repo.add",
        id: makeMessageId(),
        path: join(root, "missing"),
      },
      state,
      config,
    );
    const duplicate = handleControl(
      {
        v: 1,
        type: "repo.add",
        id: makeMessageId(),
        path: root,
      },
      state,
      config,
    );

    expect(missing[0]?.type).toBe("error");
    expect(duplicate[0]?.type).toBe("error");
  });
});
