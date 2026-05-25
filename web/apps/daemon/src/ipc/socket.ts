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
import type { DaemonConfig } from "../auth/config";
import { handleControl } from "../server";
import type { InMemoryState } from "../state/InMemoryState";

export type IPCServerHandle = {
  close: () => void;
  socketPath: string;
};

export function defaultSocketPath(): string {
  return join(homedir(), ".prowl", "prowld.sock");
}

export function startIPCServer(
  config: DaemonConfig,
  state: InMemoryState,
  socketPath = defaultSocketPath(),
): IPCServerHandle {
  mkdirSync(dirname(socketPath), { recursive: true });
  rmSync(socketPath, { force: true });

  const buffers = new WeakMap<object, Uint8Array>();
  const server = Bun.listen({
    unix: socketPath,
    socket: {
      data(socket, data) {
        const current = buffers.get(socket) ?? new Uint8Array();
        let buffer = concat(current, data);
        while (buffer.byteLength >= 5) {
          const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
          const tag = view.getUint8(0);
          const length = view.getUint32(1, false);
          if (tag === protocolTags.pty) {
            const frame = decodeFrame(buffer);
            if (frame.tag === protocolTags.pty) {
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
          for (const response of handleControl(control, state, config)) {
            socket.write(encodeJsonFrame(response));
          }
        }
        buffers.set(socket, buffer);
      },
      close(socket) {
        buffers.delete(socket);
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
      id: "invalid",
      code: "INVALID_CONTROL_MESSAGE",
      message,
    }),
  );
  socket.end();
}
