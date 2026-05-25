import { maxBinaryPayloadBytes, maxJsonPayloadBytes, protocolTags } from "./version";

const headerBytes = 5;
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

export type DecodedFrame =
  | { tag: typeof protocolTags.pty; channelId: number; payload: Uint8Array }
  | { tag: typeof protocolTags.json; payload: string };

export function encodePtyFrame(channelId: number, payload: Uint8Array): ArrayBuffer {
  if (payload.byteLength > maxBinaryPayloadBytes) {
    throw new RangeError(`PTY payload exceeds ${maxBinaryPayloadBytes} bytes`);
  }
  const frame = new Uint8Array(headerBytes + payload.byteLength);
  const view = new DataView(frame.buffer);
  view.setUint8(0, protocolTags.pty);
  view.setUint32(1, channelId, false);
  frame.set(payload, headerBytes);
  return frame.buffer;
}

export function encodeJsonFrame(value: unknown): ArrayBuffer {
  const payload = textEncoder.encode(JSON.stringify(value));
  if (payload.byteLength > maxJsonPayloadBytes) {
    throw new RangeError(`JSON payload exceeds ${maxJsonPayloadBytes} bytes`);
  }
  const frame = new Uint8Array(headerBytes + payload.byteLength);
  const view = new DataView(frame.buffer);
  view.setUint8(0, protocolTags.json);
  view.setUint32(1, payload.byteLength, false);
  frame.set(payload, headerBytes);
  return frame.buffer;
}

export function decodeFrame(input: ArrayBuffer | Uint8Array): DecodedFrame {
  const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
  if (bytes.byteLength < headerBytes) {
    throw new RangeError("Frame is shorter than the protocol header");
  }

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tag = view.getUint8(0);
  const payload = bytes.subarray(headerBytes);

  if (tag === protocolTags.pty) {
    if (payload.byteLength > maxBinaryPayloadBytes) {
      throw new RangeError(`PTY payload exceeds ${maxBinaryPayloadBytes} bytes`);
    }
    return { tag, channelId: view.getUint32(1, false), payload };
  }

  if (tag === protocolTags.json) {
    const length = view.getUint32(1, false);
    if (length !== payload.byteLength) {
      throw new RangeError(`JSON frame length mismatch: header=${length}, actual=${payload.byteLength}`);
    }
    if (payload.byteLength > maxJsonPayloadBytes) {
      throw new RangeError(`JSON payload exceeds ${maxJsonPayloadBytes} bytes`);
    }
    return { tag, payload: textDecoder.decode(payload) };
  }

  throw new RangeError(`Unknown frame tag: ${tag}`);
}
