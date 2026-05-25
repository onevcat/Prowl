import { mkdirSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import {
  ControlMessageParseError,
  decodeFrame,
  encodeJsonFrame,
  parseClientControlMessage,
  protocolTags,
} from "@prowl/protocol";
import type { ServerControlMessage } from "@prowl/protocol";
import type { DaemonConfig } from "../auth/config";
import { handleControl } from "../server";
import type { InMemoryState } from "../state/InMemoryState";

export type IPCServerHandle = {
  close: () => void;
  socketPath: string;
};

export function defaultSocketPath(): string {
  return Bun.env.PROWL_SOCKET_PATH ?? join(homedir(), ".prowl", "prowld.sock");
}

export function startIPCServer(
  config: DaemonConfig,
  state: InMemoryState,
  socketPath = defaultSocketPath(),
): IPCServerHandle {
  mkdirSync(dirname(socketPath), { recursive: true });
  rmSync(socketPath, { force: true });

  const buffers = new WeakMap<object, Uint8Array>();
  const sessions = new WeakMap<object, { authenticated: boolean; ownedPaneIds: Set<string> }>();
  const server = Bun.listen({
    unix: socketPath,
    socket: {
      open(socket) {
        sessions.set(socket, { authenticated: false, ownedPaneIds: new Set() });
      },
      data(socket, data) {
        const current = buffers.get(socket) ?? new Uint8Array();
        const session = sessions.get(socket) ?? { authenticated: false, ownedPaneIds: new Set<string>() };
        sessions.set(socket, session);
        let buffer = concat(current, data);
        while (buffer.byteLength >= 5) {
          const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
          const tag = view.getUint8(0);
          const length = view.getUint32(1, false);
          if (tag === protocolTags.pty) {
            if (buffer.byteLength === 5) {
              break;
            }
            let frame: ReturnType<typeof decodeFrame>;
            try {
              frame = decodeFrame(buffer);
            } catch (error) {
              writeInvalidControlError(socket, error);
              return;
            }
            if (frame.tag === protocolTags.pty) {
              if (!session.authenticated) {
                socket.end();
                return;
              }
              const pane = state.paneForChannel(frame.channelId);
              if (!pane || !session.ownedPaneIds.has(pane.id)) {
                socket.end();
                return;
              }
              state.writeToChannel(frame.channelId, frame.payload);
            }
            buffer = new Uint8Array();
            socket.end();
            break;
          }
          if (tag !== protocolTags.json) {
            socket.end();
            return;
          }
          const frameLength = 5 + length;
          if (buffer.byteLength < frameLength) {
            break;
          }
          const frame = buffer.subarray(0, frameLength);
          buffer = buffer.subarray(frameLength);
          let decoded: ReturnType<typeof decodeFrame>;
          try {
            decoded = decodeFrame(frame);
          } catch (error) {
            writeInvalidControlError(socket, error);
            return;
          }
          if (decoded.tag !== protocolTags.json) {
            continue;
          }
          let control: ReturnType<typeof parseClientControlMessage>;
          try {
            control = parseClientControlMessage(decoded.payload);
          } catch (error) {
            writeInvalidControlError(socket, error);
            return;
          }
          if (!session.authenticated && control.type !== "hello") {
            socket.write(
              encodeJsonFrame(errorResponse(control.id, "UNAUTHORIZED", "Send hello before other control messages")),
            );
            continue;
          }
          const responses = handleControl(control, state, config, {
            authenticated: session.authenticated,
            ownedPaneIds: session.ownedPaneIds,
          });
          if (control.type === "hello" && responses.some((response) => response.type === "welcome")) {
            session.authenticated = true;
            session.ownedPaneIds = new Set(state.listPanes().map((pane) => pane.id));
          }
          for (const response of responses) {
            socket.write(encodeJsonFrame(response));
          }
        }
        buffers.set(socket, buffer);
      },
      close(socket) {
        buffers.delete(socket);
        sessions.delete(socket);
      },
    },
  });

  return {
    socketPath,
    close: () => {
      server.stop();
      rmSync(socketPath, { force: true });
    },
  };
}

function errorResponse(id: string, code: string, message: string): Extract<ServerControlMessage, { type: "error" }> {
  return { v: 1, type: "error", id, code, message };
}

function concat(left: Uint8Array, right: Uint8Array): Uint8Array {
  const next = new Uint8Array(left.byteLength + right.byteLength);
  next.set(left, 0);
  next.set(right, left.byteLength);
  return next;
}

function writeInvalidControlError(
  socket: { write: (payload: ArrayBuffer) => void; end: () => void },
  error: unknown,
): void {
  const message = error instanceof ControlMessageParseError ? error.message : "Invalid control message";
  socket.write(
    encodeJsonFrame({
      v: 1,
      type: "error",
      id: crypto.randomUUID(),
      code: "INVALID_CONTROL_MESSAGE",
      message,
    }),
  );
  socket.end();
}
