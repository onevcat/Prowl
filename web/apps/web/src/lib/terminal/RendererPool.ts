export class RendererPool {
  readonly limit: number;
  #holders = new Map<string, number>();

  constructor(limit = 8) {
    this.limit = limit;
  }

  acquire(paneId: string): boolean {
    this.#holders.set(paneId, performance.now());
    if (this.#holders.size <= this.limit) {
      return true;
    }
    const [oldest] = Array.from(this.#holders.entries()).sort((a, b) => a[1] - b[1])[0] ?? [];
    if (oldest && oldest !== paneId) {
      this.#holders.delete(oldest);
    }
    return this.#holders.has(paneId);
  }

  release(paneId: string): void {
    this.#holders.delete(paneId);
  }

  get activeCount(): number {
    return this.#holders.size;
  }
}
