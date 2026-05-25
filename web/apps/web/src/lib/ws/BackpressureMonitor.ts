export const defaultBackpressureThresholdBytes = 256 * 1024;
export const defaultBackpressureDelayMs = 200;

export class BackpressureMonitor {
  readonly thresholdBytes: number;
  readonly delayMs: number;
  #startedAt: number | null = null;
  #buffering = false;

  constructor(thresholdBytes = defaultBackpressureThresholdBytes, delayMs = defaultBackpressureDelayMs) {
    this.thresholdBytes = thresholdBytes;
    this.delayMs = delayMs;
  }

  update(bufferedBytes: number, now: number): boolean {
    if (bufferedBytes <= this.thresholdBytes) {
      this.#startedAt = null;
      this.#buffering = false;
      return false;
    }

    this.#startedAt ??= now;
    if (now - this.#startedAt >= this.delayMs) {
      this.#buffering = true;
    }
    return this.#buffering;
  }

  get buffering(): boolean {
    return this.#buffering;
  }
}
