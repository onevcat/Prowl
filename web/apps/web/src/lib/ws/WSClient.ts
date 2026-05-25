import type { ClientControlMessage, ServerControlMessage } from "@prowl/protocol";
import { decodeFrame, encodeJsonFrame, encodePtyFrame, protocolTags } from "@prowl/protocol";

type Listener = (message: ServerControlMessage) => void;
type BinaryListener = (channelId: number, payload: Uint8Array) => void;

export class WSClient {
  #socket: WebSocket | null = null;
  #listeners = new Set<Listener>();
  #binaryListeners = new Set<BinaryListener>();

  get readyState(): number {
    return this.#socket?.readyState ?? WebSocket.CLOSED;
  }

  connect(url: string): void {
    this.#socket?.close();
    const socket = new WebSocket(url);
    socket.binaryType = "arraybuffer";
    socket.onmessage = (event) => this.#handleMessage(event.data);
    this.#socket = socket;
  }

  onMessage(listener: Listener): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  onBinary(listener: BinaryListener): () => void {
    this.#binaryListeners.add(listener);
    return () => this.#binaryListeners.delete(listener);
  }

  send(message: ClientControlMessage): void {
    this.#socket?.send(encodeJsonFrame(message));
  }

  sendBinary(channelId: number, payload: Uint8Array): void {
    if ((this.#socket?.bufferedAmount ?? 0) > 256 * 1024) {
      return;
    }
    this.#socket?.send(encodePtyFrame(channelId, payload));
  }

  #handleMessage(data: unknown): void {
    if (!(data instanceof ArrayBuffer)) {
      return;
    }
    const frame = decodeFrame(data);
    if (frame.tag === protocolTags.json) {
      const message = JSON.parse(frame.payload) as ServerControlMessage;
      for (const listener of this.#listeners) {
        listener(message);
      }
      return;
    }

    for (const listener of this.#binaryListeners) {
      listener(frame.channelId, frame.payload);
    }
  }
}
