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
    scheduler.runNext();

    expect(sent.map((frame) => frame.byteLength)).toEqual([maxBinaryPayloadBytes, 5]);
  });

  test("drains queued frames within the per-tick byte budget", () => {
    const scheduler = new ManualScheduler();
    const sent: Uint8Array[] = [];
    const coalescer = new OutputCoalescer(
      (_channelId, payload) => {
        sent.push(payload);
      },
      { maxFrameBytes: 4, maxDrainBytesPerTick: 8, scheduler },
    );

    coalescer.write(1, new Uint8Array(10));
    scheduler.runNext();
    scheduler.runNext();

    expect(sent.map((frame) => frame.byteLength)).toEqual([4, 4]);
    expect(coalescer.queuedBytes(1)).toBe(2);

    scheduler.runNext();

    expect(sent.map((frame) => frame.byteLength)).toEqual([4, 4, 2]);
    expect(coalescer.queuedBytes(1)).toBe(0);
  });

  test("reports high and low water backpressure transitions", () => {
    const scheduler = new ManualScheduler();
    const transitions: Array<{ channelId: number; backpressured: boolean }> = [];
    const coalescer = new OutputCoalescer(() => {}, {
      highWaterBytes: 8,
      lowWaterBytes: 4,
      maxFrameBytes: 4,
      maxDrainBytesPerTick: 4,
      scheduler,
      onBackpressureChange: (channelId, backpressured) => {
        transitions.push({ channelId, backpressured });
      },
    });

    coalescer.write(3, new Uint8Array(12));
    scheduler.runNext();

    expect(coalescer.isBackpressured(3)).toBe(true);
    expect(transitions).toEqual([{ channelId: 3, backpressured: true }]);

    scheduler.runNext();
    expect(coalescer.isBackpressured(3)).toBe(true);
    scheduler.runNext();

    expect(coalescer.isBackpressured(3)).toBe(false);
    expect(transitions).toEqual([
      { channelId: 3, backpressured: true },
      { channelId: 3, backpressured: false },
    ]);
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
