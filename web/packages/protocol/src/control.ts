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
  | (BaseControlMessage & { type: "repo.list" })
  | (BaseControlMessage & { type: "repo.add"; path: string })
  | (BaseControlMessage & { type: "repo.remove"; repoId: string })
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
  | (BaseControlMessage & { type: "repo.listed"; repositories: Repository[] })
  | (BaseControlMessage & { type: "worktree.listed"; repoId: string; worktrees: Worktree[] })
  | (BaseControlMessage & { type: "worktree.updated"; worktree: Worktree })
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
