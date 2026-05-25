export type UUID = string;

export type TaskStatus = "idle" | "running" | "done" | "failed";

export interface Repository {
  id: string;
  path: string;
  displayName: string;
  color: string;
}

export interface Worktree {
  id: string;
  repoId: string;
  path: string;
  name: string;
  branch: string;
  status: "clean" | "dirty" | "loading" | "archived";
  taskStatus: TaskStatus;
  unreadCount: number;
}

export interface PaneDescriptor {
  id: string;
  channelId: number;
  worktreeId: string;
  title: string;
  taskStatus: TaskStatus;
  unread: boolean;
  lastOutputLine: string;
  updatedAt: number;
}

export interface CustomAction {
  id: string;
  repoId: string | null;
  name: string;
  command: string;
  shortcut?: string;
  icon?: string;
  outputMode: "currentPane" | "newPane";
  ordering: number;
}

export interface WorktreeDiff {
  worktreeId: string;
  text: string;
  generatedAt: number;
}

export type SettingsSnapshot = Record<string, unknown>;

export interface BaseControlMessage {
  v: 1;
  type: string;
  id: UUID;
}

export type ClientControlMessage =
  | (BaseControlMessage & {
      type: "hello";
      token: string;
      clientVersion: string;
      protocolVersion: number;
    })
  | (BaseControlMessage & {
      type: "pane.create";
      worktreeId: string;
      cols: number;
      rows: number;
      cwd?: string;
      command?: string;
    })
  | (BaseControlMessage & { type: "pane.close"; paneId: string })
  | (BaseControlMessage & { type: "pane.list" })
  | (BaseControlMessage & { type: "pane.resize"; paneId: string; cols: number; rows: number })
  | (BaseControlMessage & { type: "pane.attach"; paneId: string })
  | (BaseControlMessage & { type: "pane.detach"; paneId: string })
  | (BaseControlMessage & { type: "pane.status"; paneId: string; taskStatus: TaskStatus })
  | (BaseControlMessage & { type: "worktree.list"; repoId: string })
  | (BaseControlMessage & {
      type: "worktree.create";
      repoId: string;
      branch: string;
      baseRef?: string;
      directory?: string;
    })
  | (BaseControlMessage & { type: "worktree.archive"; worktreeId: string })
  | (BaseControlMessage & { type: "worktree.diff"; worktreeId: string })
  | (BaseControlMessage & { type: "repo.list" })
  | (BaseControlMessage & { type: "repo.add"; path: string })
  | (BaseControlMessage & { type: "repo.remove"; repoId: string })
  | (BaseControlMessage & { type: "action.list"; repoId?: string })
  | (BaseControlMessage & { type: "action.upsert"; action: Omit<CustomAction, "id"> & { id?: string } })
  | (BaseControlMessage & { type: "action.delete"; actionId: string })
  | (BaseControlMessage & { type: "action.run"; paneId: string; actionId: string })
  | (BaseControlMessage & { type: "settings.get"; keys?: string[] })
  | (BaseControlMessage & { type: "settings.set"; patch: Record<string, unknown> })
  | (BaseControlMessage & { type: "ping" });

export type ServerControlMessage =
  | (BaseControlMessage & {
      type: "welcome";
      sessionId: string;
      serverVersion: string;
      capabilities: string[];
    })
  | (BaseControlMessage & {
      type: "pane.created";
      paneId: string;
      channelId: number;
      worktreeId: string;
      title?: string;
    })
  | (BaseControlMessage & { type: "pane.listed"; panes: PaneDescriptor[] })
  | (BaseControlMessage & { type: "pane.exited"; paneId: string; exitCode: number; signal?: string })
  | (BaseControlMessage & { type: "pane.resized"; paneId: string; cols: number; rows: number })
  | (BaseControlMessage & { type: "pane.replay"; paneId: string; bytes: string })
  | (BaseControlMessage & { type: "pane.detached"; paneId: string })
  | (BaseControlMessage & { type: "repo.listed"; repositories: Repository[] })
  | (BaseControlMessage & { type: "action.listed"; actions: CustomAction[] })
  | (BaseControlMessage & { type: "action.updated"; action: CustomAction })
  | (BaseControlMessage & { type: "action.deleted"; actionId: string })
  | (BaseControlMessage & { type: "worktree.listed"; repoId: string; worktrees: Worktree[] })
  | (BaseControlMessage & { type: "worktree.updated"; worktree: Worktree })
  | (BaseControlMessage & { type: "worktree.archiveProgress"; worktreeId: string; step: string; message: string })
  | (BaseControlMessage & { type: "worktree.diffed"; diff: WorktreeDiff })
  | (BaseControlMessage & { type: "repo.updated"; repository: Repository })
  | (BaseControlMessage & { type: "settings.snapshot"; settings: SettingsSnapshot })
  | (BaseControlMessage & {
      type: "notification";
      severity: "info" | "warning" | "error";
      title: string;
      body: string;
      paneId?: string;
    })
  | (BaseControlMessage & { type: "error"; code: string; message: string; correlationId?: string })
  | (BaseControlMessage & { type: "pong" });

export type ControlMessage = ClientControlMessage | ServerControlMessage;

export function makeMessageId(): string {
  return crypto.randomUUID();
}

export function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

export class ControlMessageParseError extends Error {
  readonly code = "INVALID_CONTROL_MESSAGE";

  constructor(message: string) {
    super(message);
    this.name = "ControlMessageParseError";
  }
}

export function parseClientControlMessage(payload: string): ClientControlMessage {
  let value: unknown;
  try {
    value = JSON.parse(payload);
  } catch {
    throw new ControlMessageParseError("Control message must be valid JSON");
  }
  if (!isRecord(value)) {
    throw new ControlMessageParseError("Control message must be an object");
  }
  if (value.v !== 1) {
    throw new ControlMessageParseError("Control message version must be 1");
  }
  if (typeof value.id !== "string" || !value.id) {
    throw new ControlMessageParseError("Control message id is required");
  }
  if (!isUUID(value.id)) {
    throw new ControlMessageParseError("Control message id must be a UUID");
  }
  if (typeof value.type !== "string" || !value.type) {
    throw new ControlMessageParseError("Control message type is required");
  }

  switch (value.type) {
    case "hello":
      requireString(value, "token");
      requireString(value, "clientVersion");
      requireNumber(value, "protocolVersion");
      break;
    case "pane.create":
      requireString(value, "worktreeId");
      requirePositiveInteger(value, "cols");
      requirePositiveInteger(value, "rows");
      optionalString(value, "cwd");
      optionalString(value, "command");
      break;
    case "pane.close":
    case "pane.attach":
    case "pane.detach":
      requireString(value, "paneId");
      break;
    case "pane.resize":
      requireString(value, "paneId");
      requirePositiveInteger(value, "cols");
      requirePositiveInteger(value, "rows");
      break;
    case "pane.status":
      requireString(value, "paneId");
      if (!isTaskStatus(value.taskStatus)) {
        throw new ControlMessageParseError("pane.status taskStatus is invalid");
      }
      break;
    case "worktree.list":
      requireString(value, "repoId");
      break;
    case "worktree.create":
      requireString(value, "repoId");
      requireString(value, "branch");
      optionalString(value, "baseRef");
      optionalString(value, "directory");
      break;
    case "worktree.archive":
    case "worktree.diff":
      requireString(value, "worktreeId");
      break;
    case "repo.add":
      requireString(value, "path");
      break;
    case "repo.remove":
      requireString(value, "repoId");
      break;
    case "action.list":
      optionalString(value, "repoId");
      break;
    case "action.upsert":
      validateAction(value.action);
      break;
    case "action.delete":
      requireString(value, "actionId");
      break;
    case "action.run":
      requireString(value, "paneId");
      requireString(value, "actionId");
      break;
    case "settings.get":
      if (value.keys !== undefined && !isStringArray(value.keys)) {
        throw new ControlMessageParseError("settings.get keys must be an array of strings");
      }
      break;
    case "settings.set":
      if (!isRecord(value.patch)) {
        throw new ControlMessageParseError("settings.set patch must be an object");
      }
      break;
    case "repo.list":
    case "pane.list":
    case "ping":
      break;
    default:
      throw new ControlMessageParseError(`Unsupported control message type: ${value.type}`);
  }

  return value as unknown as ClientControlMessage;
}

function validateAction(value: unknown): void {
  if (!isRecord(value)) {
    throw new ControlMessageParseError("action.upsert action must be an object");
  }
  optionalString(value, "id");
  if (value.repoId !== null) {
    optionalString(value, "repoId");
  }
  requireString(value, "name");
  requireString(value, "command");
  optionalString(value, "shortcut");
  optionalString(value, "icon");
  if (value.outputMode !== "currentPane" && value.outputMode !== "newPane") {
    throw new ControlMessageParseError("action.upsert action outputMode is invalid");
  }
  requireNumber(value, "ordering");
}

function requireString(value: Record<string, unknown>, key: string): void {
  if (typeof value[key] !== "string") {
    throw new ControlMessageParseError(`${key} must be a string`);
  }
}

function optionalString(value: Record<string, unknown>, key: string): void {
  if (value[key] !== undefined && typeof value[key] !== "string") {
    throw new ControlMessageParseError(`${key} must be a string`);
  }
}

function requireNumber(value: Record<string, unknown>, key: string): void {
  if (typeof value[key] !== "number" || !Number.isFinite(value[key])) {
    throw new ControlMessageParseError(`${key} must be a finite number`);
  }
}

function requirePositiveInteger(value: Record<string, unknown>, key: string): void {
  requireNumber(value, key);
  const numberValue = value[key];
  if (typeof numberValue !== "number" || !Number.isInteger(numberValue) || numberValue < 1) {
    throw new ControlMessageParseError(`${key} must be a positive integer`);
  }
}

function isTaskStatus(value: unknown): value is TaskStatus {
  return value === "idle" || value === "running" || value === "done" || value === "failed";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === "string");
}
