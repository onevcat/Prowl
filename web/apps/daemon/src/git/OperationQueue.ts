export class GitOperationQueue {
  #tails = new Map<string, Promise<void>>();

  async run<T>(repoId: string, operation: () => T | Promise<T>): Promise<T> {
    const previous = this.#tails.get(repoId);
    let releaseCurrent = () => {};
    const current = new Promise<void>((resolve) => {
      releaseCurrent = resolve;
    });
    const tail = (previous ?? Promise.resolve()).catch(() => {}).then(() => current);
    this.#tails.set(repoId, tail);

    if (previous) {
      await previous.catch(() => {});
    }
    try {
      return await operation();
    } finally {
      releaseCurrent();
      if (this.#tails.get(repoId) === tail) {
        this.#tails.delete(repoId);
      }
    }
  }

  get size(): number {
    return this.#tails.size;
  }
}
