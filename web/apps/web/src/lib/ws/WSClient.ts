import type { ClientControlMessage, ServerControlMessage } from "@prowl/protocol";
import { decodeFrame, encodeJsonFrame, encodePtyFrame, protocolTags } from "@prowl/protocol";
import { BackpressureMonitor, defaultBackpressureDelayMs } from "./BackpressureMonitor";

type Listener = (message: ServerControlMessage) => void;
type BinaryListener = (channelId: number, payload: Uint8Array) => void;
type StatusListener = (state: "connecting" | "open" | "closed") => void;
type BackpressureListener = (buffering: boolean) => void;

const reconnectDelayMs = 100;

export class ProtocolError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "ProtocolError";
  }
}

export class WSClient {
  #socket: WebSocket | null = null;
  #url: string | null = null;
  #connectGeneration = 0;
  #manualClose = false;
  #reconnectTimer: ReturnType<typeof setTimeout> | null = null;
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
  #backpressure = new BackpressureMonitor();
  #backpressureListeners = new Set<BackpressureListener>();
  #backpressureTimer: ReturnType<typeof setTimeout> | null = null;

  get readyState(): number {
    return this.#socket?.readyState ?? WebSocket.CLOSED;
  }

  connect(url: string): void {
    this.#url = url;
    this.#manualClose = false;
    this.#openSocket(++this.#connectGeneration);
  }

  disconnect(): void {
    this.#manualClose = true;
    this.#connectGeneration += 1;
    if (this.#reconnectTimer) {
      clearTimeout(this.#reconnectTimer);
      this.#reconnectTimer = null;
    }
    this.#clearBackpressureTimer();
    this.#backpressure.update(0, performance.now());
    this.#emitBackpressure(false);
    this.#socket?.close();
    this.#socket = null;
    this.#rejectPending(new Error("WebSocket disconnected"));
    this.#emitStatus("closed");
  }

  #openSocket(generation: number): void {
    if (!this.#url) {
      return;
    }
    this.#socket?.close();
    this.#emitStatus("connecting");
    const socket = new WebSocket(this.#url);
    socket.binaryType = "arraybuffer";
    socket.onopen = () => {
      if (generation !== this.#connectGeneration) {
        return;
      }
      this.#emitStatus("open");
    };
    socket.onmessage = (event) => this.#handleMessage(event.data);
    socket.onclose = () => {
      if (generation !== this.#connectGeneration) {
        return;
      }
      this.#rejectPending(new Error("WebSocket closed"));
      this.#emitStatus("closed");
      this.#scheduleReconnect(generation);
    };
    socket.onerror = () => {
      if (generation !== this.#connectGeneration) {
        return;
      }
      this.#rejectPending(new Error("WebSocket error"));
      this.#emitStatus("closed");
      this.#scheduleReconnect(generation);
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

  onBackpressure(listener: BackpressureListener): () => void {
    this.#backpressureListeners.add(listener);
    return () => this.#backpressureListeners.delete(listener);
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

  sendBinary(channelId: number, payload: Uint8Array): boolean {
    const socket = this.#socket;
    if (socket?.readyState !== WebSocket.OPEN) {
      return false;
    }
    if (this.#updateBackpressure(socket.bufferedAmount)) {
      this.#scheduleBackpressureCheck();
      return false;
    }
    socket.send(encodePtyFrame(channelId, payload));
    return true;
  }

  #handleMessage(data: unknown): void {
    if (!(data instanceof ArrayBuffer) && !(data instanceof Uint8Array)) {
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
          pending.reject(new ProtocolError(message.code, message.message));
          return;
        }
        pending.resolve(message);
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

  #scheduleReconnect(generation: number): void {
    if (this.#manualClose || generation !== this.#connectGeneration || this.#reconnectTimer) {
      return;
    }
    this.#reconnectTimer = setTimeout(() => {
      this.#reconnectTimer = null;
      if (this.#manualClose || generation !== this.#connectGeneration) {
        return;
      }
      this.#openSocket(generation);
    }, reconnectDelayMs);
  }

  #updateBackpressure(bufferedAmount: number): boolean {
    const buffering = this.#backpressure.update(bufferedAmount, performance.now());
    this.#emitBackpressure(buffering);
    if (!buffering && bufferedAmount <= this.#backpressure.thresholdBytes) {
      this.#clearBackpressureTimer();
    }
    return bufferedAmount > this.#backpressure.thresholdBytes;
  }

  #scheduleBackpressureCheck(): void {
    if (this.#backpressureTimer) {
      return;
    }
    this.#backpressureTimer = setTimeout(() => {
      this.#backpressureTimer = null;
      const socket = this.#socket;
      if (socket?.readyState !== WebSocket.OPEN) {
        this.#backpressure.update(0, performance.now());
        this.#emitBackpressure(false);
        return;
      }
      if (this.#updateBackpressure(socket.bufferedAmount)) {
        this.#scheduleBackpressureCheck();
      }
    }, defaultBackpressureDelayMs);
  }

  #clearBackpressureTimer(): void {
    if (!this.#backpressureTimer) {
      return;
    }
    clearTimeout(this.#backpressureTimer);
    this.#backpressureTimer = null;
  }

  #emitBackpressure(buffering: boolean): void {
    for (const listener of this.#backpressureListeners) {
      listener(buffering);
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
