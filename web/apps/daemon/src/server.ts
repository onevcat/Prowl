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
import { type IPCServerHandle, startIPCServer } from "./ipc/socket";
import { InMemoryState } from "./state/InMemoryState";

export type ServerHandle = {
  stop: () => void;
  state: InMemoryState;
};

export function startServer(
  config: DaemonConfig,
  options: { socketPath?: string | false; statePath?: string; spawnProcesses?: boolean } = {},
): ServerHandle {
  const clients = new Set<{ send: (payload: ArrayBuffer) => void }>();
  const state = new InMemoryState(process.env.PROWL_REPO_ROOT ?? process.cwd(), {
    spawnProcesses: options.spawnProcesses,
    statePath: options.statePath,
    onPaneData: (channelId, payload) => {
      for (let offset = 0; offset < payload.byteLength; offset += maxBinaryPayloadBytes) {
        const frame = encodePtyFrame(channelId, payload.subarray(offset, offset + maxBinaryPayloadBytes));
        for (const client of clients) {
          client.send(frame);
        }
      }
    },
  });
  let ipc: IPCServerHandle | null = null;
  if (options.socketPath !== false) {
    ipc = startIPCServer(config, state, options.socketPath);
  }
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
    state,
    stop: () => {
      ipc?.close();
      server.stop(true);
    },
  };
}

export function handleControl(
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

  if (message.type === "repo.add") {
    const { repository, worktree } = state.addRepository(message.path);
    return [
      { v: 1, type: "repo.updated", id: message.id, repository },
      { v: 1, type: "worktree.updated", id: message.id, worktree },
    ];
  }

  if (message.type === "repo.remove") {
    state.removeRepository(message.repoId);
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

  if (message.type === "settings.set") {
    return [{ v: 1, type: "settings.snapshot", id: message.id, settings: state.updateSettings(message.patch) }];
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

  if (message.type === "pane.attach") {
    const replay = state.replayForPane(message.paneId);
    if (!replay) {
      return [errorResponse(message.id, "PANE_GONE", "Pane is no longer available")];
    }
    return [
      {
        v: 1,
        type: "pane.replay",
        id: message.id,
        paneId: message.paneId,
        bytes: Buffer.from(replay).toString("base64"),
      },
    ];
  }

  if (message.type === "pane.resize") {
    state.resizePane(message.paneId, message.cols, message.rows);
    return [
      {
        v: 1,
        type: "pane.resized",
        id: message.id,
        paneId: message.paneId,
        cols: message.cols,
        rows: message.rows,
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
