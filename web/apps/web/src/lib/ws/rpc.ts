import type { ClientControlMessage, ServerControlMessage } from "@prowl/protocol";
import { makeMessageId } from "@prowl/protocol";

export type PendingRequest = {
  resolve: (message: ServerControlMessage) => void;
  reject: (error: Error) => void;
};

export function withMessageId<T extends Omit<ClientControlMessage, "id" | "v">>(message: T): T & { v: 1; id: string } {
  return { ...message, v: 1, id: makeMessageId() };
}
