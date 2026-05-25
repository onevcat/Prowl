import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ClientControlMessage, ServerControlMessage } from "@prowl/protocol";
import {
  decodeFrame,
  encodeJsonFrame,
  encodePtyFrame,
  makeMessageId,
  protocolTags,
  protocolVersion,
} from "@prowl/protocol";

export type CLIConfig = {
  token: string;
};

const authenticatedTokenBySocketPath = new Map<string, string>();

export function defaultSocketPath(): string {
  return Bun.env.PROWL_SOCKET_PATH ?? join(homedir(), ".prowl", "prowld.sock");
}

export function defaultConfigPath(): string {
  return Bun.env.PROWL_CONFIG_PATH ?? join(homedir(), ".prowl", "config.json");
}

export async function loadCLIConfig(): Promise<CLIConfig> {
  return JSON.parse(await readFile(defaultConfigPath(), "utf8")) as CLIConfig;
}

export async function requestDaemon(
  message: ClientControlMessage,
  socketPath = defaultSocketPath(),
): Promise<ServerControlMessage> {
  const authToken = message.type === "hello" ? undefined : await tokenForSocketPath(socketPath);
  return new Promise((resolve, reject) => {
    let settled = false;
    let buffer: Uint8Array<ArrayBuffer> = new Uint8Array();
    const timer = setTimeout(() => {
      fail(new Error(`Timed out waiting for daemon response to ${message.type}`));
    }, 3000);

    function finish(response: ServerControlMessage): void {
      if (settled) {
        return;
      }
      if (authToken && response.type === "welcome") {
        return;
      }
      settled = true;
      clearTimeout(timer);
      if (response.type === "error") {
        reject(new Error(`${response.code}: ${response.message}`));
      } else {
        if (message.type === "hello" && response.type === "welcome") {
          authenticatedTokenBySocketPath.set(socketPath, message.token);
        }
        resolve(response);
      }
    }

    function fail(error: Error): void {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      reject(error);
    }

    void Bun.connect({
      unix: socketPath,
      socket: {
        open(socket) {
          if (authToken) {
            socket.write(
              encodeJsonFrame({
                v: 1,
                type: "hello",
                id: makeMessageId(),
                token: authToken,
                clientVersion: "0.0.0",
                protocolVersion,
              }),
            );
          }
          socket.write(encodeJsonFrame(message));
        },
        data(socket, data) {
          buffer = concat(buffer, data);
          while (buffer.byteLength >= 5) {
            const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
            const tag = view.getUint8(0);
            const length = view.getUint32(1, false);
            if (tag !== protocolTags.json) {
              socket.end();
              fail(new Error("Unexpected non-JSON daemon response"));
              return;
            }
            const frameLength = 5 + length;
            if (buffer.byteLength < frameLength) {
              return;
            }
            const frame = buffer.subarray(0, frameLength);
            buffer = buffer.subarray(frameLength);
            const decoded = decodeFrame(frame);
            if (decoded.tag !== protocolTags.json) {
              socket.end();
              fail(new Error("Unexpected daemon response frame"));
              return;
            }
            finish(JSON.parse(decoded.payload) as ServerControlMessage);
            if (settled) {
              socket.end();
              return;
            }
          }
        },
        close() {
          fail(new Error(`Daemon closed the connection before responding to ${message.type}`));
        },
        error(_socket, error) {
          fail(error);
        },
      },
    }).catch((error: unknown) => {
      fail(error instanceof Error ? error : new Error(String(error)));
    });
  });
}

export async function sendPtyInput(
  channelId: number,
  payload: Uint8Array,
  socketPath = defaultSocketPath(),
): Promise<void> {
  const authToken = await tokenForSocketPath(socketPath);
  await new Promise<void>((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(() => {
      fail(new Error("Timed out sending PTY input to daemon"));
    }, 3000);

    function finish(): void {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve();
    }

    function fail(error: Error): void {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      reject(error);
    }

    void Bun.connect({
      unix: socketPath,
      socket: {
        open(socket) {
          if (authToken) {
            socket.write(
              encodeJsonFrame({
                v: 1,
                type: "hello",
                id: makeMessageId(),
                token: authToken,
                clientVersion: "0.0.0",
                protocolVersion,
              }),
            );
          }
          socket.write(encodePtyFrame(channelId, payload));
          socket.end();
          finish();
        },
        data() {},
        error(_socket, error) {
          fail(error);
        },
        close() {
          finish();
        },
      },
    }).catch((error: unknown) => {
      fail(error instanceof Error ? error : new Error(String(error)));
    });
  });
}

export async function hello(token: string, socketPath = defaultSocketPath()): Promise<void> {
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
  authenticatedTokenBySocketPath.set(socketPath, token);
}

async function tokenForSocketPath(socketPath: string): Promise<string | undefined> {
  const cached = authenticatedTokenBySocketPath.get(socketPath);
  if (cached) {
    return cached;
  }
  try {
    const config = await loadCLIConfig();
    authenticatedTokenBySocketPath.set(socketPath, config.token);
    return config.token;
  } catch {
    return undefined;
  }
}

function concat(left: Uint8Array<ArrayBuffer>, right: Uint8Array<ArrayBufferLike>): Uint8Array<ArrayBuffer> {
  const next = new Uint8Array(left.byteLength + right.byteLength);
  next.set(left, 0);
  next.set(right, left.byteLength);
  return next;
}
