import { maxBinaryPayloadBytes } from "@prowl/protocol";

type ScheduledHandle = unknown;

type Scheduler = {
  setTimeout: (callback: () => void, delayMs: number) => ScheduledHandle;
  clearTimeout: (handle: ScheduledHandle) => void;
};

type PendingOutput = {
  chunks: Uint8Array[];
  byteLength: number;
  timer: ScheduledHandle;
};

export type OutputCoalescerOptions = {
  delayMs?: number;
  maxFrameBytes?: number;
  scheduler?: Scheduler;
};

const defaultDelayMs = 4;

const defaultScheduler: Scheduler = {
  setTimeout: (callback, delayMs) => setTimeout(callback, delayMs),
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

export class OutputCoalescer {
  #pendingByChannel = new Map<number, PendingOutput>();
  #delayMs: number;
  #maxFrameBytes: number;
  #scheduler: Scheduler;

  constructor(
    private readonly send: (channelId: number, payload: Uint8Array) => void,
    options: OutputCoalescerOptions = {},
  ) {
    this.#delayMs = options.delayMs ?? defaultDelayMs;
    this.#maxFrameBytes = options.maxFrameBytes ?? maxBinaryPayloadBytes;
    this.#scheduler = options.scheduler ?? defaultScheduler;
  }

  write(channelId: number, payload: Uint8Array): void {
    if (payload.byteLength === 0) {
      return;
    }
    const pending = this.#pendingByChannel.get(channelId);
    if (pending) {
      pending.chunks.push(payload);
      pending.byteLength += payload.byteLength;
      return;
    }

    const timer = this.#scheduler.setTimeout(() => this.flush(channelId), this.#delayMs);
    this.#pendingByChannel.set(channelId, {
      chunks: [payload],
      byteLength: payload.byteLength,
      timer,
    });
  }

  flush(channelId: number): void {
    const pending = this.#pendingByChannel.get(channelId);
    if (!pending) {
      return;
    }
    this.#pendingByChannel.delete(channelId);
    const combined = new Uint8Array(pending.byteLength);
    let offset = 0;
    for (const chunk of pending.chunks) {
      combined.set(chunk, offset);
      offset += chunk.byteLength;
    }
    for (let frameOffset = 0; frameOffset < combined.byteLength; frameOffset += this.#maxFrameBytes) {
      this.send(channelId, combined.subarray(frameOffset, frameOffset + this.#maxFrameBytes));
    }
  }

  flushAll(): void {
    for (const [channelId, pending] of this.#pendingByChannel) {
      this.#scheduler.clearTimeout(pending.timer);
      this.flush(channelId);
    }
  }
}
