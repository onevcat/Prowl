import { describe, expect, test } from "bun:test";
import {
  decodeFrame,
  encodeJsonFrame,
  encodePtyFrame,
  makeMessageId,
  protocolTags,
  protocolVersion,
} from "@prowl/protocol";
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

  test("accepts split PTY frames over the daemon unix socket", async () => {
    const token = "test-token";
    const socketPath = `/tmp/prowld-split-pty-test-${crypto.randomUUID()}.sock`;
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
      await sendSplitPtyInput(pane.channelId, new TextEncoder().encode("printf cli-split-pty\r"), socketPath);
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
        "cli-split-pty",
      );
    } finally {
      server.stop();
    }
  });

  test("returns protocol errors for malformed control messages over the daemon unix socket", async () => {
    const token = "test-token";
    const socketPath = `/tmp/prowld-invalid-control-test-${crypto.randomUUID()}.sock`;
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
      const response = await sendRawJson(socketPath, { v: 1, type: "pane.resize", id: crypto.randomUUID() });

      expect(response.type).toBe("error");
      if (response.type === "error") {
        expect(response.code).toBe("INVALID_CONTROL_MESSAGE");
        expect(response.message).toContain("paneId must be a string");
      }
    } finally {
      server.stop();
    }
  });

  test("rejects control messages before hello over the daemon unix socket", async () => {
    const token = "test-token";
    const socketPath = `/tmp/prowld-unauthorized-control-test-${crypto.randomUUID()}.sock`;
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
      const response = await sendRawJson(socketPath, {
        v: 1,
        type: "settings.get",
        id: crypto.randomUUID(),
        keys: ["panes"],
      });

      expect(response.type).toBe("error");
      if (response.type === "error") {
        expect(response.code).toBe("UNAUTHORIZED");
      }
    } finally {
      server.stop();
    }
  });
});

async function sendRawJson(socketPath: string, value: unknown): Promise<ReturnType<typeof JSON.parse>> {
  return new Promise((resolve, reject) => {
    let buffer: Uint8Array<ArrayBufferLike> = new Uint8Array();
    void Bun.connect({
      unix: socketPath,
      socket: {
        open(socket) {
          socket.write(encodeJsonFrame(value));
        },
        data(socket, data) {
          buffer = concat(buffer, data);
          if (buffer.byteLength < 5) {
            return;
          }
          const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
          if (view.getUint8(0) !== protocolTags.json) {
            socket.end();
            reject(new Error("Expected JSON frame"));
            return;
          }
          const frameLength = 5 + view.getUint32(1, false);
          if (buffer.byteLength < frameLength) {
            return;
          }
          const decoded = decodeFrame(buffer.subarray(0, frameLength));
          socket.end();
          if (decoded.tag !== protocolTags.json) {
            reject(new Error("Expected JSON response"));
            return;
          }
          resolve(JSON.parse(decoded.payload));
        },
        close() {},
        error(_socket, error) {
          reject(error);
        },
      },
    }).catch(reject);
  });
}

async function sendSplitPtyInput(channelId: number, payload: Uint8Array, socketPath: string): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const frame = new Uint8Array(encodePtyFrame(channelId, payload));
    void Bun.connect({
      unix: socketPath,
      socket: {
        open(socket) {
          socket.write(
            encodeJsonFrame({
              v: 1,
              type: "hello",
              id: makeMessageId(),
              token: "test-token",
              clientVersion: "0.0.0",
              protocolVersion,
            }),
          );
          socket.write(frame.subarray(0, 5));
          setTimeout(() => {
            socket.write(frame.subarray(5));
            socket.end();
            resolve();
          }, 1);
        },
        data() {},
        close() {},
        error(_socket, error) {
          reject(error);
        },
      },
    }).catch(reject);
  });
}

function concat(left: Uint8Array, right: Uint8Array<ArrayBufferLike>): Uint8Array {
  const next = new Uint8Array(left.byteLength + right.byteLength);
  next.set(left, 0);
  next.set(new Uint8Array(right), left.byteLength);
  return next;
}
