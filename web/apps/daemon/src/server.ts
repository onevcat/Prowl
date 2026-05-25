import { statSync } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import type { BaseControlMessage, ClientControlMessage, ServerControlMessage } from "@prowl/protocol";
import { decodeFrame, encodeJsonFrame, encodePtyFrame, protocolTags, protocolVersion } from "@prowl/protocol";
import type { DaemonConfig } from "./auth/config";
import { isAllowedOrigin } from "./auth/config";
import { type IPCServerHandle, startIPCServer } from "./ipc/socket";
import { type Logger, createLogger } from "./logging/logger";
import { OutputCoalescer } from "./pty/OutputCoalescer";
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
type WebSocketData = {
  authenticated: boolean;
  controlWindowStartedAt: number;
  controlMessagesInWindow: number;
};

const maxControlMessagesPerSecond = 100;

export type ServerHandle = {
  stop: () => void;
  state: InMemoryState;
  url: URL;
  port: number;
};

type ServerOptions = {
  socketPath?: string | false;
  statePath?: string;
  spawnProcesses?: boolean;
  logger?: Logger;
  debugEndpoints?: boolean;
};

type DebugStats = {
  paneAttachRequests: number;
  paneCreateRequests: number;
};

export function startServer(config: DaemonConfig, options: ServerOptions = {}): ServerHandle {
  const tls = tlsOptions(config);
  const logger = options.logger ?? createLogger();
  const clients = new Set<{ send: (payload: ArrayBuffer) => void; close: (code?: number, reason?: string) => void }>();
  const debugStats: DebugStats = {
    paneAttachRequests: 0,
    paneCreateRequests: 0,
  };
  const outputCoalescer = new OutputCoalescer((channelId, payload) => {
    const frame = encodePtyFrame(channelId, payload);
    for (const client of clients) {
      client.send(frame);
    }
  });
  const state = new InMemoryState(process.env.PROWL_REPO_ROOT ?? process.cwd(), {
    spawnProcesses: options.spawnProcesses,
    statePath: options.statePath,
    onPaneData: (channelId, payload) => {
      outputCoalescer.write(channelId, payload);
    },
    onPaneExit: (paneId, exitCode) => {
      logger.info(`pane exited paneId=${paneId} exitCode=${exitCode}`);
      const frame = encodeJsonFrame({
        v: 1,
        type: "pane.exited",
        id: crypto.randomUUID(),
        paneId,
        exitCode,
      } satisfies ServerControlMessage);
      for (const client of clients) {
        client.send(frame);
      }
    },
  });
  let ipc: IPCServerHandle | null = null;
  if (options.socketPath !== false) {
    ipc = startIPCServer(config, state, options.socketPath);
    logger.debug(`ipc listening on ${ipc.socketPath}`);
  }
  const server = Bun.serve<WebSocketData>({
    hostname: config.bind,
    port: config.port,
    ...(tls ? { tls } : {}),
    fetch(request, server) {
      const url = new URL(request.url);
      if (url.pathname === "/health") {
        return Response.json({ ok: true, protocolVersion });
      }

      if (options.debugEndpoints && url.pathname === "/debug/close-websockets") {
        for (const client of clients) {
          client.close(1012, "Debug reconnect test");
        }
        return Response.json({ closed: true });
      }

      if (options.debugEndpoints && url.pathname === "/debug/stats") {
        return Response.json(debugStats);
      }

      if (options.debugEndpoints && url.pathname === "/debug/drop-first-pane") {
        const pane = state.listPanes()[0];
        if (!pane) {
          return Response.json({ dropped: false });
        }
        state.closePane(pane.id);
        return Response.json({ dropped: true, paneId: pane.id });
      }

      if (url.pathname === "/auth/login") {
        if (request.method === "OPTIONS") {
          return handleLoginPreflight(request, config, logger);
        }
        return handleLogin(request, config, Boolean(tls), logger);
      }

      if (url.pathname !== "/ws") {
        return new Response("Not found", { status: 404 });
      }

      if (!isAllowedOrigin(config, request.headers.get("Origin"))) {
        logger.warn(`rejected websocket origin=${request.headers.get("Origin") ?? "missing"}`);
        return new Response("Forbidden origin", { status: 403 });
      }

      const token = tokenFromRequest(request, url);
      if (token !== config.token) {
        logger.warn("rejected websocket unauthorized token");
        return new Response("Unauthorized", { status: 401 });
      }

      if (
        !server.upgrade(request, {
          data: {
            authenticated: true,
            controlWindowStartedAt: Date.now(),
            controlMessagesInWindow: 0,
          },
        })
      ) {
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

        let frame: ReturnType<typeof decodeFrame>;
        try {
          frame = decodeFrame(message);
        } catch {
          logger.warn("closing websocket after invalid frame");
          ws.close(1009, "Invalid frame");
          return;
        }
        if (frame.tag === protocolTags.pty) {
          state.writeToChannel(frame.channelId, frame.payload);
          return;
        }

        if (!allowControlMessage(ws.data)) {
          logger.warn("closing websocket after control rate limit");
          ws.close(1008, "Control rate limit exceeded");
          return;
        }

        const control = JSON.parse(frame.payload) as ClientControlMessage;
        if (control.type === "pane.attach") {
          debugStats.paneAttachRequests += 1;
        }
        if (control.type === "pane.create") {
          debugStats.paneCreateRequests += 1;
        }
        const responses = handleControl(control, state, config, { authenticated: ws.data.authenticated });
        for (const response of responses) {
          ws.send(encodeJsonFrame(response));
        }
      },
    },
  });

  return {
    state,
    url: server.url,
    port: server.port ?? config.port,
    stop: () => {
      outputCoalescer.flushAll();
      ipc?.close();
      server.stop(true);
      logger.info("daemon stopped");
    },
  };
}

export function allowControlMessage(session: WebSocketData, now = Date.now()): boolean {
  if (now - session.controlWindowStartedAt >= 1_000) {
    session.controlWindowStartedAt = now;
    session.controlMessagesInWindow = 0;
  }
  session.controlMessagesInWindow += 1;
  return session.controlMessagesInWindow <= maxControlMessagesPerSecond;
}

async function handleLogin(
  request: Request,
  config: DaemonConfig,
  secureCookie: boolean,
  logger: Logger,
): Promise<Response> {
  if (request.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  if (!isAllowedOrigin(config, request.headers.get("Origin"))) {
    logger.warn(`rejected login origin=${request.headers.get("Origin") ?? "missing"}`);
    return new Response("Forbidden origin", { status: 403 });
  }

  const headers = loginCorsHeaders(request, config);
  const token = await tokenFromLoginBody(request);
  if (token !== config.token) {
    logger.warn("rejected login unauthorized token");
    return new Response("Unauthorized", { status: 401, headers });
  }

  logger.info("issued auth session cookie");
  return Response.json(
    { ok: true },
    {
      headers: {
        ...headers,
        "Set-Cookie": sessionCookie(config.token, secureCookie),
      },
    },
  );
}

function handleLoginPreflight(request: Request, config: DaemonConfig, logger: Logger): Response {
  if (!isAllowedOrigin(config, request.headers.get("Origin"))) {
    logger.warn(`rejected login preflight origin=${request.headers.get("Origin") ?? "missing"}`);
    return new Response("Forbidden origin", { status: 403 });
  }
  return new Response(null, { status: 204, headers: loginCorsHeaders(request, config) });
}

function loginCorsHeaders(request: Request, config: DaemonConfig): Record<string, string> {
  const origin = request.headers.get("Origin");
  if (!origin || !isAllowedOrigin(config, origin)) {
    return {};
  }
  return {
    "Access-Control-Allow-Credentials": "true",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Origin": origin,
    Vary: "Origin",
  };
}

async function tokenFromLoginBody(request: Request): Promise<string> {
  const contentType = request.headers.get("Content-Type") ?? "";
  if (contentType.includes("application/json")) {
    const body = await request.json().catch(() => null);
    return isRecord(body) && typeof body.token === "string" ? body.token : "";
  }
  return (await request.text()).trim();
}

function tokenFromRequest(request: Request, url: URL): string | null {
  return url.searchParams.get("token") ?? cookieValue(request.headers.get("Cookie"), "prowl_session");
}

function cookieValue(cookieHeader: string | null, name: string): string | null {
  if (!cookieHeader) {
    return null;
  }
  for (const cookie of cookieHeader.split(";")) {
    const [rawName, ...rawValue] = cookie.trim().split("=");
    if (rawName === name) {
      return decodeURIComponent(rawValue.join("="));
    }
  }
  return null;
}

function sessionCookie(token: string, secure: boolean): string {
  const secureAttribute = secure ? "; Secure" : "";
  return `prowl_session=${encodeURIComponent(token)}; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000${secureAttribute}`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function tlsOptions(config: DaemonConfig): Bun.TLSOptions | null {
  if (!config.tlsCertPath && !config.tlsKeyPath) {
    if (config.requireTLS) {
      throw new Error("TLS is required for this bind; provide --tls-cert and --tls-key or bind to loopback.");
    }
    return null;
  }

  if (!config.tlsCertPath || !config.tlsKeyPath) {
    throw new Error("Both --tls-cert and --tls-key are required to enable TLS.");
  }

  return {
    cert: Bun.file(config.tlsCertPath),
    key: Bun.file(config.tlsKeyPath),
  };
}

export function handleControl(
  message: ClientControlMessage,
  state: InMemoryState,
  config: DaemonConfig,
  options: { authenticated?: boolean } = {},
): ServerControlMessage[] {
  if (message.type === "hello") {
    if (!options.authenticated && message.token !== config.token) {
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
    if (!state.repository(message.repoId)) {
      return [errorResponse(message.id, "REPO_NOT_FOUND", "Repository is no longer registered")];
    }
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
    if (!state.repository(message.repoId)) {
      return [errorResponse(message.id, "REPO_NOT_FOUND", "Repository is no longer registered")];
    }
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
    const worktree = state.worktree(message.worktreeId);
    if (!worktree) {
      return [errorResponse(message.id, "WORKTREE_NOT_FOUND", "Worktree is no longer registered")];
    }
    const cwd = resolvePaneCwd(message.id, worktree.path, message.cwd);
    if (cwd.type === "error") {
      return [cwd];
    }
    const pane = state.createPane(message.worktreeId, "Shell", message.command, cwd.path);
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
    if (!state.closePane(message.paneId)) {
      return [errorResponse(message.id, "PANE_GONE", "Pane is no longer available")];
    }
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
    if (!state.resizePane(message.paneId, message.cols, message.rows)) {
      return [errorResponse(message.id, "PANE_GONE", "Pane is no longer available")];
    }
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

function resolvePaneCwd(
  id: string,
  worktreePath: string,
  cwd?: string,
): { type: "ok"; path: string | undefined } | ErrorControlMessage {
  if (!cwd?.trim()) {
    return { type: "ok", path: undefined };
  }
  const worktreeRoot = resolve(worktreePath);
  const requestedPath = isAbsolute(cwd) ? resolve(cwd) : resolve(worktreeRoot, cwd);
  if (requestedPath !== worktreeRoot && !requestedPath.startsWith(`${worktreeRoot}/`)) {
    return errorResponse(id, "INVALID_PANE_CWD", "Pane cwd must stay inside the worktree");
  }
  try {
    if (!statSync(requestedPath).isDirectory()) {
      return errorResponse(id, "INVALID_PANE_CWD", "Pane cwd must be a directory");
    }
  } catch {
    return errorResponse(id, "INVALID_PANE_CWD", "Pane cwd does not exist");
  }
  return { type: "ok", path: requestedPath };
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
