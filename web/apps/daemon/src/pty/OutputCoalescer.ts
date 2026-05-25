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

type QueuedOutput = {
  frames: Uint8Array[];
  byteLength: number;
  timer: ScheduledHandle | null;
};

export type OutputCoalescerOptions = {
  delayMs?: number;
  maxFrameBytes?: number;
  highWaterBytes?: number;
  lowWaterBytes?: number;
  maxDrainBytesPerTick?: number;
  onBackpressureChange?: (channelId: number, backpressured: boolean) => void;
  scheduler?: Scheduler;
};

const defaultDelayMs = 4;
const defaultHighWaterBytes = 1024 * 1024;
const defaultLowWaterBytes = 256 * 1024;

const defaultScheduler: Scheduler = {
  setTimeout: (callback, delayMs) => setTimeout(callback, delayMs),
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

export class OutputCoalescer {
  #pendingByChannel = new Map<number, PendingOutput>();
  #queuedByChannel = new Map<number, QueuedOutput>();
  #backpressuredChannels = new Set<number>();
  #delayMs: number;
  #maxFrameBytes: number;
  #highWaterBytes: number;
  #lowWaterBytes: number;
  #maxDrainBytesPerTick: number;
  #onBackpressureChange?: (channelId: number, backpressured: boolean) => void;
  #scheduler: Scheduler;

  constructor(
    private readonly send: (channelId: number, payload: Uint8Array) => void,
    options: OutputCoalescerOptions = {},
  ) {
    this.#delayMs = options.delayMs ?? defaultDelayMs;
    this.#maxFrameBytes = options.maxFrameBytes ?? maxBinaryPayloadBytes;
    this.#highWaterBytes = options.highWaterBytes ?? defaultHighWaterBytes;
    this.#lowWaterBytes = options.lowWaterBytes ?? defaultLowWaterBytes;
    this.#maxDrainBytesPerTick = options.maxDrainBytesPerTick ?? this.#lowWaterBytes;
    this.#onBackpressureChange = options.onBackpressureChange;
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
      this.#enqueueFrame(channelId, combined.subarray(frameOffset, frameOffset + this.#maxFrameBytes));
    }
    this.#scheduleDrain(channelId);
  }

  flushAll(): void {
    for (const [channelId, pending] of this.#pendingByChannel) {
      this.#scheduler.clearTimeout(pending.timer);
      this.flush(channelId);
    }
    for (const [channelId, queued] of this.#queuedByChannel) {
      if (queued.timer) {
        this.#scheduler.clearTimeout(queued.timer);
        queued.timer = null;
      }
      this.#drain(channelId, Number.POSITIVE_INFINITY);
    }
  }

  queuedBytes(channelId: number): number {
    return this.#queuedByChannel.get(channelId)?.byteLength ?? 0;
  }

  isBackpressured(channelId: number): boolean {
    return this.#backpressuredChannels.has(channelId);
  }

  #enqueueFrame(channelId: number, frame: Uint8Array): void {
    const queued = this.#queuedByChannel.get(channelId) ?? {
      frames: [],
      byteLength: 0,
      timer: null,
    };
    queued.frames.push(frame);
    queued.byteLength += frame.byteLength;
    this.#queuedByChannel.set(channelId, queued);
    this.#updateBackpressure(channelId, queued.byteLength);
  }

  #scheduleDrain(channelId: number): void {
    const queued = this.#queuedByChannel.get(channelId);
    if (!queued || queued.timer) {
      return;
    }
    queued.timer = this.#scheduler.setTimeout(() => {
      const current = this.#queuedByChannel.get(channelId);
      if (current) {
        current.timer = null;
      }
      this.#drain(channelId, this.#maxDrainBytesPerTick);
    }, 0);
  }

  #drain(channelId: number, budgetBytes: number): void {
    const queued = this.#queuedByChannel.get(channelId);
    if (!queued) {
      return;
    }
    let drainedBytes = 0;
    while (queued.frames.length > 0) {
      const frame = queued.frames[0];
      if (!frame) {
        break;
      }
      if (drainedBytes > 0 && drainedBytes + frame.byteLength > budgetBytes) {
        break;
      }
      queued.frames.shift();
      queued.byteLength -= frame.byteLength;
      drainedBytes += frame.byteLength;
      this.send(channelId, frame);
    }

    this.#updateBackpressure(channelId, queued.byteLength);
    if (queued.frames.length === 0) {
      this.#queuedByChannel.delete(channelId);
      return;
    }
    this.#scheduleDrain(channelId);
  }

  #updateBackpressure(channelId: number, queuedBytes: number): void {
    if (!this.#backpressuredChannels.has(channelId) && queuedBytes > this.#highWaterBytes) {
      this.#backpressuredChannels.add(channelId);
      this.#onBackpressureChange?.(channelId, true);
      return;
    }
    if (this.#backpressuredChannels.has(channelId) && queuedBytes <= this.#lowWaterBytes) {
      this.#backpressuredChannels.delete(channelId);
      this.#onBackpressureChange?.(channelId, false);
    }
  }
}
