import type { ClientControlMessage, ServerControlMessage } from "@prowl/protocol";
import {
  decodeFrame,
  encodeJsonFrame,
  encodePtyFrame,
  maxBinaryPayloadBytes,
  protocolTags,
  protocolVersion,
} from "@prowl/protocol";
import type { DaemonConfig } from "./auth/config";
import { isAllowedOrigin } from "./auth/config";
import { InMemoryState } from "./state/InMemoryState";

export type ServerHandle = {
  stop: () => void;
};

export function startServer(config: DaemonConfig): ServerHandle {
  const clients = new Set<{ send: (payload: ArrayBuffer) => void }>();
  const state = new InMemoryState(process.env.PROWL_REPO_ROOT ?? process.cwd(), {
    onPaneData: (channelId, payload) => {
      for (let offset = 0; offset < payload.byteLength; offset += maxBinaryPayloadBytes) {
        const frame = encodePtyFrame(channelId, payload.subarray(offset, offset + maxBinaryPayloadBytes));
        for (const client of clients) {
          client.send(frame);
        }
      }
    },
  });
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
      open(ws) {
        clients.add(ws);
      },
      close(ws) {
        clients.delete(ws);
      },
      message(ws, message) {
        if (typeof message === "string") {
          return;
        }

        const frame = decodeFrame(message);
        if (frame.tag === protocolTags.pty) {
          state.writeToChannel(frame.channelId, frame.payload);
          return;
        }

        const control = JSON.parse(frame.payload) as ClientControlMessage;
        const responses = handleControl(control, state, config);
        for (const response of responses) {
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
  state: InMemoryState,
  config: DaemonConfig,
): ServerControlMessage[] {
  if (message.type === "hello") {
    if (message.token !== config.token) {
      return [errorResponse(message.id, "UNAUTHORIZED", "Invalid token")];
    }
    if (message.protocolVersion > protocolVersion) {
      return [errorResponse(message.id, "PROTOCOL_MISMATCH", "Client protocol is newer than daemon")];
    }
    return [
      {
        v: 1,
        type: "welcome",
        id: message.id,
        sessionId: crypto.randomUUID(),
        serverVersion: "0.0.0",
        capabilities: ["repo.list", "worktree.list", "pane.create", "pane.close", "settings.get", "ping"],
      },
    ];
  }

  if (message.type === "repo.list") {
    return [{ v: 1, type: "repo.listed", id: message.id, repositories: state.repositories }];
  }

  if (message.type === "worktree.list") {
    return [
      {
        v: 1,
        type: "worktree.listed",
        id: message.id,
        repoId: message.repoId,
        worktrees: state.worktreesByRepo.get(message.repoId) ?? [],
      },
    ];
  }

  if (message.type === "settings.get") {
    return [{ v: 1, type: "settings.snapshot", id: message.id, settings: state.settingsSnapshot(message.keys) }];
  }

  if (message.type === "pane.create") {
    const pane = state.createPane(message.worktreeId, "Shell", message.command);
    return [
      {
        v: 1,
        type: "pane.created",
        id: message.id,
        paneId: pane.id,
        channelId: pane.channelId,
        worktreeId: pane.worktreeId,
        title: pane.title,
      },
    ];
  }

  if (message.type === "pane.close") {
    state.closePane(message.paneId);
    return [
      {
        v: 1,
        type: "pane.exited",
        id: message.id,
        paneId: message.paneId,
        exitCode: 0,
      },
    ];
  }

  if (message.type === "ping") {
    return [{ v: 1, type: "pong", id: message.id }];
  }

  return [errorResponse(message.id, "NOT_IMPLEMENTED", `${message.type} is not implemented yet`)];
}

function errorResponse(id: string, code: string, message: string): ServerControlMessage {
  return { v: 1, type: "error", id, code, message };
}
