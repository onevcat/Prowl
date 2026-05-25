import type { ClientControlMessage, ServerControlMessage } from "@prowl/protocol";
import { decodeFrame, encodeJsonFrame, protocolTags, protocolVersion } from "@prowl/protocol";
import type { DaemonConfig } from "./auth/config";
import { isAllowedOrigin } from "./auth/config";
import { PaneManager } from "./pty/PaneManager";

export type ServerHandle = {
  stop: () => void;
};

export function startServer(config: DaemonConfig): ServerHandle {
  const paneManager = new PaneManager();
  const server = Bun.serve({
    hostname: config.bind,
    port: config.port,
    fetch(request, server) {
      const url = new URL(request.url);
      if (url.pathname === "/health") {
        return Response.json({ ok: true, protocolVersion });
      }

      if (url.pathname !== "/ws") {
        return new Response("Not found", { status: 404 });
      }

      if (!isAllowedOrigin(config, request.headers.get("Origin"))) {
        return new Response("Forbidden origin", { status: 403 });
      }

      const token = url.searchParams.get("token");
      if (token && token !== config.token) {
        return new Response("Unauthorized", { status: 401 });
      }

      if (!server.upgrade(request)) {
        return new Response("Upgrade failed", { status: 400 });
      }
    },
    websocket: {
      message(ws, message) {
        if (!(message instanceof ArrayBuffer)) {
          return;
        }

        const frame = decodeFrame(message);
        if (frame.tag === protocolTags.pty) {
          return;
        }

        const control = JSON.parse(frame.payload) as ClientControlMessage;
        const response = handleControl(control, paneManager, config);
        if (response) {
          ws.send(encodeJsonFrame(response));
        }
      },
    },
  });

  return {
    stop: () => server.stop(true),
  };
}

function handleControl(
  message: ClientControlMessage,
  paneManager: PaneManager,
  config: DaemonConfig,
): ServerControlMessage | null {
  if (message.type === "hello") {
    if (message.token !== config.token) {
      return errorResponse(message.id, "UNAUTHORIZED", "Invalid token");
    }
    if (message.protocolVersion > protocolVersion) {
      return errorResponse(message.id, "PROTOCOL_MISMATCH", "Client protocol is newer than daemon");
    }
    return {
      v: 1,
      type: "welcome",
      id: message.id,
      sessionId: crypto.randomUUID(),
      serverVersion: "0.0.0",
      capabilities: ["pane.create", "pane.close", "ping"],
    };
  }

  if (message.type === "pane.create") {
    const pane = paneManager.create(message.worktreeId);
    return {
      v: 1,
      type: "pane.created",
      id: message.id,
      paneId: pane.id,
      channelId: pane.channelId,
      worktreeId: pane.worktreeId,
      title: pane.title,
    };
  }

  if (message.type === "pane.close") {
    paneManager.close(message.paneId);
    return {
      v: 1,
      type: "pane.exited",
      id: message.id,
      paneId: message.paneId,
      exitCode: 0,
    };
  }

  if (message.type === "ping") {
    return { v: 1, type: "pong", id: message.id };
  }

  return errorResponse(message.id, "NOT_IMPLEMENTED", `${message.type} is not implemented yet`);
}

function errorResponse(id: string, code: string, message: string): ServerControlMessage {
  return { v: 1, type: "error", id, code, message };
}
