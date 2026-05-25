export const protocolVersion = 1;

export const protocolTags = {
  pty: 0x01,
  json: 0x02,
} as const;

export const maxBinaryPayloadBytes = 4 * 1024;
export const maxJsonPayloadBytes = 64 * 1024;
