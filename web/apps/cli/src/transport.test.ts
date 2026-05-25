import { describe, expect, test } from "bun:test";
import { makeMessageId, protocolVersion } from "@prowl/protocol";
import { startServer } from "../../daemon/src/server";
import { requestDaemon, sendPtyInput } from "./transport";

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

  test("sends PTY input frames over the daemon unix socket", async () => {
    const token = "test-token";
    const socketPath = `/tmp/prowld-pty-test-${crypto.randomUUID()}.sock`;
    const server = startServer(
      {
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      },
      { socketPath, statePath: ":memory:", spawnProcesses: true },
    );

    try {
      await Bun.sleep(50);
      await requestDaemon(
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
      if (panes.type !== "settings.snapshot" || !Array.isArray(panes.settings.panes)) {
        throw new Error("Expected pane snapshot");
      }
      const pane = panes.settings.panes[0];
      await sendPtyInput(pane.channelId, new TextEncoder().encode("printf cli-pty-smoke\r"), socketPath);
      await Bun.sleep(200);
      const replay = await requestDaemon(
        {
          v: 1,
          type: "pane.attach",
          id: makeMessageId(),
          paneId: pane.id,
        },
        socketPath,
      );

      expect(replay.type).toBe("pane.replay");
      expect(replay.type === "pane.replay" ? Buffer.from(replay.bytes, "base64").toString("utf8") : "").toContain(
        "cli-pty-smoke",
      );
    } finally {
      server.stop();
    }
  });
});
