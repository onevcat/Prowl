import { afterEach, describe, expect, test, vi } from "vitest";
import { WSClient } from "./WSClient";

const originalWebSocket = globalThis.WebSocket;

afterEach(() => {
  vi.useRealTimers();
  Object.defineProperty(globalThis, "WebSocket", {
    configurable: true,
    value: originalWebSocket,
  });
});

describe("WSClient backpressure", () => {
  test("keeps polling while blocked and clears buffering after the socket drains", async () => {
    installFakeWebSocket();
    const client = new WSClient();
    const bufferingStates: boolean[] = [];
    client.onBackpressure((buffering) => bufferingStates.push(buffering));

    client.connect("ws://127.0.0.1:7878/ws");
    const socket = FakeWebSocket.instances.at(-1);
    expect(socket).toBeDefined();
    if (!socket) {
      return;
    }
    socket.open();
    socket.bufferedAmount = 256 * 1024 + 1;

    expect(client.sendBinary(1, new TextEncoder().encode("input"))).toBe(false);
    await sleep(220);

    expect(bufferingStates.at(-1)).toBe(true);
    socket.bufferedAmount = 0;
    await sleep(220);

    expect(bufferingStates.at(-1)).toBe(false);
  });
});

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function installFakeWebSocket(): void {
  FakeWebSocket.instances = [];
  Object.defineProperty(globalThis, "WebSocket", {
    configurable: true,
    value: FakeWebSocket,
  });
}

class FakeWebSocket {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSED = 3;
  static instances: FakeWebSocket[] = [];

  binaryType: BinaryType = "blob";
  bufferedAmount = 0;
  readyState = FakeWebSocket.CONNECTING;
  onopen: (() => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;

  constructor(readonly url: string) {
    FakeWebSocket.instances.push(this);
  }

  open(): void {
    this.readyState = FakeWebSocket.OPEN;
    this.onopen?.();
  }

  close(): void {
    this.readyState = FakeWebSocket.CLOSED;
    this.onclose?.();
  }

  send(_payload: ArrayBuffer): void {}
}
