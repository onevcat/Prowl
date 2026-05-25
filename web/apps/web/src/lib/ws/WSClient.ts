import type { ClientControlMessage, ServerControlMessage } from "@prowl/protocol";
import { decodeFrame, encodeJsonFrame, encodePtyFrame, protocolTags } from "@prowl/protocol";

type Listener = (message: ServerControlMessage) => void;
type BinaryListener = (channelId: number, payload: Uint8Array) => void;
type StatusListener = (state: "connecting" | "open" | "closed") => void;

export class WSClient {
  #socket: WebSocket | null = null;
  #listeners = new Set<Listener>();
  #binaryListeners = new Set<BinaryListener>();
  #statusListeners = new Set<StatusListener>();
  #pending = new Map<
    string,
    {
      resolve: (message: ServerControlMessage) => void;
      reject: (error: Error) => void;
      timer: ReturnType<typeof setTimeout>;
    }
  >();

  get readyState(): number {
    return this.#socket?.readyState ?? WebSocket.CLOSED;
  }

  connect(url: string): void {
    this.#socket?.close();
    this.#emitStatus("connecting");
    const socket = new WebSocket(url);
    socket.binaryType = "arraybuffer";
    socket.onopen = () => this.#emitStatus("open");
    socket.onmessage = (event) => this.#handleMessage(event.data);
    socket.onclose = () => {
      this.#rejectPending(new Error("WebSocket closed"));
      this.#emitStatus("closed");
    };
    socket.onerror = () => {
      this.#rejectPending(new Error("WebSocket error"));
      this.#emitStatus("closed");
    };
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

  onStatus(listener: StatusListener): () => void {
    this.#statusListeners.add(listener);
    return () => this.#statusListeners.delete(listener);
  }

  send(message: ClientControlMessage): void {
    if (this.#socket?.readyState !== WebSocket.OPEN) {
      return;
    }
    this.#socket.send(encodeJsonFrame(message));
  }

  request(message: ClientControlMessage, timeoutMs = 5000): Promise<ServerControlMessage> {
    if (this.#socket?.readyState !== WebSocket.OPEN) {
      return Promise.reject(new Error("WebSocket is not open"));
    }
    const requestId = message.id;
    const promise = new Promise<ServerControlMessage>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(requestId);
        reject(new Error(`Request timed out: ${message.type}`));
      }, timeoutMs);
      this.#pending.set(requestId, { resolve, reject, timer });
    });
    this.#socket.send(encodeJsonFrame(message));
    return promise;
  }

  sendBinary(channelId: number, payload: Uint8Array): void {
    if (this.#socket?.readyState !== WebSocket.OPEN) {
      return;
    }
    if ((this.#socket?.bufferedAmount ?? 0) > 256 * 1024) {
      return;
    }
    this.#socket.send(encodePtyFrame(channelId, payload));
  }

  #handleMessage(data: unknown): void {
    if (!(data instanceof ArrayBuffer)) {
      return;
    }
    const frame = decodeFrame(data);
    if (frame.tag === protocolTags.json) {
      const message = JSON.parse(frame.payload) as ServerControlMessage;
      const pending = this.#pending.get(message.id);
      if (pending) {
        clearTimeout(pending.timer);
        this.#pending.delete(message.id);
        if (message.type === "error") {
          pending.reject(new Error(`${message.code}: ${message.message}`));
        } else {
          pending.resolve(message);
        }
      }
      for (const listener of this.#listeners) {
        listener(message);
      }
      return;
    }

    for (const listener of this.#binaryListeners) {
      listener(frame.channelId, frame.payload);
    }
  }

  #emitStatus(state: "connecting" | "open" | "closed"): void {
    for (const listener of this.#statusListeners) {
      listener(state);
    }
  }

  #rejectPending(error: Error): void {
    for (const [id, pending] of this.#pending) {
      clearTimeout(pending.timer);
      pending.reject(error);
      this.#pending.delete(id);
    }
  }
}
