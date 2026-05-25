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
    await waitUntil(() => bufferingStates.at(-1) === true);

    expect(bufferingStates.at(-1)).toBe(true);
    socket.bufferedAmount = 0;
    await waitUntil(() => bufferingStates.at(-1) === false);

    expect(bufferingStates.at(-1)).toBe(false);
  });
});

async function waitUntil(done: () => boolean): Promise<void> {
  const deadline = performance.now() + 1_000;
  while (performance.now() < deadline) {
    if (done()) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error("Timed out waiting for backpressure state");
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
