import { describe, expect, test } from "bun:test";
import { makeMessageId, protocolVersion } from "@prowl/protocol";
import { startServer } from "../../daemon/src/server";
import { requestDaemon } from "./transport";

describe("CLI transport", () => {
  test("round trips control messages over the daemon unix socket", async () => {
    const token = "test-token";
    const socketPath = `/tmp/prowld-test-${crypto.randomUUID()}.sock`;
    const server = startServer(
      {
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      },
      { socketPath, statePath: ":memory:", spawnProcesses: false },
    );

    try {
      await Bun.sleep(50);
      const welcome = await requestDaemon(
        {
          v: 1,
          type: "hello",
          id: makeMessageId(),
          token,
          clientVersion: "0.0.0",
          protocolVersion,
        },
        socketPath,
      );
      const panes = await requestDaemon(
        {
          v: 1,
          type: "settings.get",
          id: makeMessageId(),
          keys: ["panes"],
        },
        socketPath,
      );

      expect(welcome.type).toBe("welcome");
      expect(panes.type).toBe("settings.snapshot");
    } finally {
      server.stop();
    }
  });
});
