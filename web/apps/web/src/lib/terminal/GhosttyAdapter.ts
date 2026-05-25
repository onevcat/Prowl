export type TerminalAdapter = {
  write(data: Uint8Array | string): void;
  input(data: Uint8Array): void;
  focus(): void;
  dispose(): void;
};

export class PlaceholderTerminalAdapter implements TerminalAdapter {
  #onWrite: (text: string) => void;

  constructor(onWrite: (text: string) => void) {
    this.#onWrite = onWrite;
  }

  write(data: Uint8Array | string): void {
    const text = typeof data === "string" ? data : new TextDecoder().decode(data);
    this.#onWrite(text);
  }

  input(data: Uint8Array): void {
    this.write(data);
  }

  focus(): void {}

  dispose(): void {}
}
