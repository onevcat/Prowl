import { describe, expect, test } from "bun:test";
import { maxBinaryPayloadBytes } from "@prowl/protocol";
import { OutputCoalescer } from "./OutputCoalescer";

describe("OutputCoalescer", () => {
  test("coalesces writes for the same channel inside the flush window", () => {
    const scheduler = new ManualScheduler();
    const sent: Array<{ channelId: number; text: string }> = [];
    const coalescer = new OutputCoalescer(
      (channelId, payload) => {
        sent.push({ channelId, text: new TextDecoder().decode(payload) });
      },
      { scheduler },
    );

    coalescer.write(7, new TextEncoder().encode("hello "));
    coalescer.write(7, new TextEncoder().encode("world"));

    expect(sent).toHaveLength(0);
    scheduler.runNext();
    expect(sent).toEqual([{ channelId: 7, text: "hello world" }]);
  });

  test("splits coalesced output into protocol-sized frames", () => {
    const scheduler = new ManualScheduler();
    const sent: Uint8Array[] = [];
    const coalescer = new OutputCoalescer(
      (_channelId, payload) => {
        sent.push(payload);
      },
      { scheduler },
    );
    const payload = new Uint8Array(maxBinaryPayloadBytes + 5);

    coalescer.write(1, payload);
    scheduler.runNext();

    expect(sent.map((frame) => frame.byteLength)).toEqual([maxBinaryPayloadBytes, 5]);
  });
});

class ManualScheduler {
  #callbacks: Array<() => void> = [];

  setTimeout(callback: () => void): () => void {
    this.#callbacks.push(callback);
    return callback;
  }

  clearTimeout(handle: unknown): void {
    this.#callbacks = this.#callbacks.filter((callback) => callback !== handle);
  }

  runNext(): void {
    const callback = this.#callbacks.shift();
    if (!callback) {
      throw new Error("Expected a scheduled callback");
    }
    callback();
  }
}
