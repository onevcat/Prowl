import { statSync } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import type { BaseControlMessage, ClientControlMessage, ServerControlMessage } from "@prowl/protocol";
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

type ErrorControlMessage = Extract<ServerControlMessage, { type: "error" }>;
type WorktreeResult =
  | { type: "ok"; worktree: NonNullable<ReturnType<InMemoryState["worktree"]>> }
  | ErrorControlMessage;
type SyncCommandResult = {
  exitCode: number | null;
  stdout: Uint8Array;
  stderr: Uint8Array;
};

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
        capabilities: [
          "repo.list",
          "repo.add",
          "repo.remove",
          "worktree.list",
          "worktree.create",
          "worktree.archive",
          "worktree.diff",
          "action.list",
          "action.upsert",
          "action.delete",
          "action.run",
          "pane.create",
          "pane.close",
          "pane.attach",
          "pane.detach",
          "pane.resize",
          "settings.get",
          "settings.set",
          "ping",
        ],
      },
    ];
  }

  if (message.type === "repo.list") {
    return [{ v: 1, type: "repo.listed", id: message.id, repositories: state.repositories }];
  }

  if (message.type === "repo.add") {
    const path = message.path.trim();
    const validationError = validateRepositoryPath(message.id, path, state);
    if (validationError) {
      return [validationError];
    }
    const { repository, worktree } = state.addRepository(path);
    return [
      { v: 1, type: "repo.updated", id: message.id, repository },
      { v: 1, type: "worktree.updated", id: message.id, worktree },
    ];
  }

  if (message.type === "repo.remove") {
    state.removeRepository(message.repoId);
    return [{ v: 1, type: "repo.listed", id: message.id, repositories: state.repositories }];
  }

  if (message.type === "action.list") {
    return [{ v: 1, type: "action.listed", id: message.id, actions: state.listCustomActions(message.repoId) }];
  }

  if (message.type === "action.upsert") {
    const validationError = validateCustomAction(message.id, message.action, state);
    if (validationError) {
      return [validationError];
    }
    return [{ v: 1, type: "action.updated", id: message.id, action: state.upsertCustomAction(message.action) }];
  }

  if (message.type === "action.delete") {
    state.deleteCustomAction(message.actionId);
    return [{ v: 1, type: "action.deleted", id: message.id, actionId: message.actionId }];
  }

  if (message.type === "action.run") {
    const result = state.runCustomAction(message.paneId, message.actionId);
    if (!result) {
      return [errorResponse(message.id, "ACTION_NOT_FOUND", "Custom action or pane is no longer available")];
    }
    const responses: ServerControlMessage[] = [];
    if (result.pane) {
      responses.push({
        v: 1,
        type: "pane.created",
        id: message.id,
        paneId: result.pane.id,
        channelId: result.pane.channelId,
        worktreeId: result.pane.worktreeId,
        title: result.pane.title,
      });
    }
    responses.push({
      v: 1,
      type: "notification",
      id: message.id,
      severity: "info",
      title: "Action started",
      body: result.action.name,
      paneId: result.pane?.id ?? message.paneId,
    });
    return responses;
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

  if (message.type === "worktree.create") {
    const result = createGitWorktree(message, state);
    if (result.type === "error") {
      return [result];
    }
    return [{ v: 1, type: "worktree.updated", id: message.id, worktree: result.worktree }];
  }

  if (message.type === "worktree.archive") {
    const result = archiveGitWorktree(message.id, message.worktreeId, state);
    if (result.type === "error") {
      return [result];
    }
    return [{ v: 1, type: "worktree.updated", id: message.id, worktree: result.worktree }];
  }

  if (message.type === "worktree.diff") {
    const result = readWorktreeDiff(message.id, message.worktreeId, state);
    if (result.type === "error") {
      return [result];
    }
    return [{ v: 1, type: "worktree.diffed", id: message.id, diff: result.diff }];
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

  if (message.type === "pane.detach") {
    if (!state.hasPane(message.paneId)) {
      return [errorResponse(message.id, "PANE_GONE", "Pane is no longer available")];
    }
    return [{ v: 1, type: "pane.detached", id: message.id, paneId: message.paneId }];
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

  if (message.type === "pane.status") {
    const pane = state.updatePaneStatus(message.paneId, message.taskStatus);
    if (!pane) {
      return [errorResponse(message.id, "PANE_GONE", "Pane is no longer available")];
    }
    if (message.taskStatus === "done") {
      return [
        {
          v: 1,
          type: "notification",
          id: message.id,
          severity: "info",
          title: "Task finished",
          body: `${pane.title}: ${pane.lastOutputLine}`,
          paneId: pane.id,
        },
      ];
    }
    return [{ v: 1, type: "pane.listed", id: message.id, panes: state.listPanes() }];
  }

  if (message.type === "ping") {
    return [{ v: 1, type: "pong", id: message.id }];
  }

  const unknownMessage = message as BaseControlMessage;
  return [errorResponse(unknownMessage.id, "NOT_IMPLEMENTED", `${unknownMessage.type} is not implemented yet`)];
}

function errorResponse(id: string, code: string, message: string): ErrorControlMessage {
  return { v: 1, type: "error", id, code, message };
}

function validateRepositoryPath(id: string, path: string, state: InMemoryState): ErrorControlMessage | null {
  const normalizedPath = path.trim();
  if (!normalizedPath) {
    return errorResponse(id, "INVALID_REPOSITORY", "Repository path is required");
  }
  try {
    if (!statSync(normalizedPath).isDirectory()) {
      return errorResponse(id, "INVALID_REPOSITORY", "Repository path must be a directory");
    }
  } catch {
    return errorResponse(id, "INVALID_REPOSITORY", "Repository path does not exist");
  }
  if (state.hasRepositoryPath(normalizedPath)) {
    return errorResponse(id, "DUPLICATE_REPOSITORY", "Repository is already registered");
  }
  return null;
}

function createGitWorktree(
  message: Extract<ClientControlMessage, { type: "worktree.create" }>,
  state: InMemoryState,
): WorktreeResult {
  const repository = state.repository(message.repoId);
  if (!repository) {
    return errorResponse(message.id, "REPO_NOT_FOUND", "Repository is no longer registered");
  }
  const branch = message.branch.trim();
  const branchError = validateBranchName(message.id, branch);
  if (branchError) {
    return branchError;
  }
  const targetPath = resolveWorktreePath(repository.path, branch, message.directory);
  if (!targetPath.startsWith(`${resolve(dirname(repository.path))}/`)) {
    return errorResponse(message.id, "INVALID_WORKTREE_PATH", "Worktree directory must stay beside the repository");
  }
  if (state.worktreesByRepo.get(repository.id)?.some((worktree) => resolve(worktree.path) === targetPath)) {
    return errorResponse(message.id, "DUPLICATE_WORKTREE", "Worktree path is already registered");
  }
  const gitError = runGitWorktreeAdd(repository.path, targetPath, branch, message.baseRef);
  if (gitError) {
    return errorResponse(message.id, "GIT_WORKTREE_FAILED", gitError);
  }
  return { type: "ok", worktree: state.createWorktree(repository.id, targetPath, branch) };
}

function archiveGitWorktree(id: string, worktreeId: string, state: InMemoryState): WorktreeResult {
  const worktree = state.worktree(worktreeId);
  if (!worktree) {
    return errorResponse(id, "WORKTREE_NOT_FOUND", "Worktree is no longer registered");
  }
  const repository = state.repository(worktree.repoId);
  if (!repository) {
    return errorResponse(id, "REPO_NOT_FOUND", "Repository is no longer registered");
  }
  const gitError = runGitWorktreeRemove(repository.path, worktree.path);
  if (gitError) {
    return errorResponse(id, "GIT_WORKTREE_FAILED", gitError);
  }
  const archived = state.archiveWorktree(worktreeId);
  if (!archived) {
    return errorResponse(id, "WORKTREE_NOT_FOUND", "Worktree is no longer registered");
  }
  return { type: "ok", worktree: archived };
}

function readWorktreeDiff(
  id: string,
  worktreeId: string,
  state: InMemoryState,
): { type: "ok"; diff: { worktreeId: string; text: string; generatedAt: number } } | ErrorControlMessage {
  const worktree = state.worktree(worktreeId);
  if (!worktree) {
    return errorResponse(id, "WORKTREE_NOT_FOUND", "Worktree is no longer registered");
  }
  const result = Bun.spawnSync(["git", "-C", worktree.path, "diff", "--no-color"], { stdout: "pipe", stderr: "pipe" });
  if (result.exitCode !== 0) {
    return errorResponse(id, "GIT_DIFF_FAILED", commandError(result));
  }
  return {
    type: "ok",
    diff: {
      worktreeId,
      text: new TextDecoder().decode(result.stdout),
      generatedAt: Date.now(),
    },
  };
}

function validateBranchName(id: string, branch: string): ErrorControlMessage | null {
  if (!branch) {
    return errorResponse(id, "INVALID_BRANCH", "Branch name is required");
  }
  if (!/^[A-Za-z0-9._/-]+$/.test(branch) || branch.includes("..") || branch.startsWith("/") || branch.endsWith("/")) {
    return errorResponse(id, "INVALID_BRANCH", "Branch name contains unsupported characters");
  }
  return null;
}

function validateCustomAction(
  id: string,
  action: Extract<ClientControlMessage, { type: "action.upsert" }>["action"],
  state: InMemoryState,
): ErrorControlMessage | null {
  if (!action.name.trim()) {
    return errorResponse(id, "INVALID_ACTION", "Action name is required");
  }
  if (!action.command.trim()) {
    return errorResponse(id, "INVALID_ACTION", "Action command is required");
  }
  if (action.repoId && !state.repository(action.repoId)) {
    return errorResponse(id, "REPO_NOT_FOUND", "Repository is no longer registered");
  }
  if (action.outputMode !== "currentPane" && action.outputMode !== "newPane") {
    return errorResponse(id, "INVALID_ACTION", "Unsupported action output mode");
  }
  return null;
}

function resolveWorktreePath(repoPath: string, branch: string, directory?: string): string {
  const base = resolve(dirname(repoPath));
  if (!directory?.trim()) {
    return join(base, basename(branch));
  }
  const trimmed = directory.trim();
  return isAbsolute(trimmed) ? resolve(trimmed) : resolve(base, trimmed);
}

function runGitWorktreeAdd(repoPath: string, targetPath: string, branch: string, baseRef?: string): string | null {
  const args = ["-C", repoPath, "worktree", "add", "-b", branch, targetPath, baseRef?.trim() || "HEAD"];
  const result = Bun.spawnSync(["git", ...args], { stdout: "pipe", stderr: "pipe" });
  return result.exitCode === 0 ? null : commandError(result);
}

function runGitWorktreeRemove(repoPath: string, worktreePath: string): string | null {
  const result = Bun.spawnSync(["git", "-C", repoPath, "worktree", "remove", "--force", worktreePath], {
    stdout: "pipe",
    stderr: "pipe",
  });
  return result.exitCode === 0 ? null : commandError(result);
}

function commandError(result: SyncCommandResult): string {
  const stderr = new TextDecoder().decode(result.stderr).trim();
  const stdout = new TextDecoder().decode(result.stdout).trim();
  return stderr || stdout || `git exited with ${result.exitCode}`;
}
