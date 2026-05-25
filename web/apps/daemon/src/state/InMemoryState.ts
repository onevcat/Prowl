import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { CustomAction, PaneDescriptor, Repository, SettingsSnapshot, Worktree } from "@prowl/protocol";
import { schemaSql } from "./schema";

type PaneProcess = {
  kill: () => void;
  exited: Promise<number>;
  terminal?: {
    write: (payload: string | Uint8Array) => void;
    resize: (cols: number, rows: number) => void;
    close: () => void;
  };
};

type StateOptions = {
  spawnProcesses?: boolean;
  spawnPaneProcess?: (options: {
    shell: string;
    args: string[];
    cwd: string;
    onData: (data: Uint8Array) => void;
  }) => PaneProcess;
  onPaneData?: (channelId: number, payload: Uint8Array) => void;
  onPaneExit?: (paneId: string, exitCode: number) => void;
  shell?: string;
  statePath?: string;
};

const replayBufferBytes = 64 * 1024;

type RepoRow = {
  id: string;
  path: string;
  display_name: string | null;
  appearance_json: string | null;
};

type WorktreeRow = {
  id: string;
  repo_id: string;
  path: string;
  branch: string | null;
  status: string | null;
  task_status: string | null;
  metadata_json: string | null;
};

type SettingRow = {
  key: string;
  value_json: string;
};

type CustomActionRow = {
  id: string;
  repo_id: string | null;
  name: string;
  command: string;
  shortcut: string | null;
  icon: string | null;
  output_mode: string | null;
  ordering: number;
};

type PaneRuntime = {
  process: PaneProcess;
};

export type RunCustomActionResult = {
  action: CustomAction;
  pane?: PaneDescriptor;
};

export class InMemoryState {
  repositories: Repository[] = [];
  readonly worktreesByRepo = new Map<string, Worktree[]>();
  #database: Database;
  #panes = new Map<string, PaneDescriptor>();
  #replayByPane = new Map<string, Uint8Array>();
  #runtimesByPane = new Map<string, PaneRuntime>();
  #paneIdByChannel = new Map<number, string>();
  #nextChannelId = 1;
  #options: Required<StateOptions>;

  constructor(repoPath = process.cwd(), options: StateOptions = {}) {
    this.#options = {
      spawnProcesses: options.spawnProcesses ?? true,
      spawnPaneProcess: options.spawnPaneProcess ?? spawnTerminalProcess,
      onPaneData: options.onPaneData ?? (() => {}),
      onPaneExit: options.onPaneExit ?? (() => {}),
      shell: options.shell ?? "/bin/sh",
      statePath: options.statePath ?? defaultStatePath(),
    };
    this.#database = openDatabase(this.#options.statePath);
    this.#database.exec(schemaSql);
    migrateDatabase(this.#database);
    this.#ensureSeedRepository(repoPath);
    this.#reloadRepositories();
    this.#reloadWorktrees();
    const worktree = this.worktreesByRepo.get(this.repositories[0]?.id ?? "")?.[0];
    if (worktree) {
      this.createPane(worktree.id, "Shell");
    }
  }

  addRepository(path: string): { repository: Repository; worktree: Worktree } {
    const repository: Repository = {
      id: crypto.randomUUID(),
      path,
      displayName: displayName(path),
      color: "#0a84ff",
    };
    const worktree: Worktree = {
      id: crypto.randomUUID(),
      repoId: repository.id,
      path,
      name: displayName(path),
      branch: "main",
      status: "clean",
      taskStatus: "idle",
      unreadCount: 0,
    };
    this.#insertRepository(repository);
    this.#insertWorktree(worktree);
    this.#reloadRepositories();
    this.#reloadWorktrees();
    return { repository, worktree };
  }

  hasRepositoryPath(path: string): boolean {
    return this.repositories.some((repository) => repository.path === path);
  }

  repository(repoId: string): Repository | null {
    return this.repositories.find((repository) => repository.id === repoId) ?? null;
  }

  worktree(worktreeId: string): Worktree | null {
    for (const worktrees of this.worktreesByRepo.values()) {
      const worktree = worktrees.find((candidate) => candidate.id === worktreeId);
      if (worktree) {
        return worktree;
      }
    }
    return null;
  }

  createWorktree(repoId: string, path: string, branch: string): Worktree {
    const worktree: Worktree = {
      id: crypto.randomUUID(),
      repoId,
      path,
      name: displayName(path),
      branch,
      status: "clean",
      taskStatus: "idle",
      unreadCount: 0,
    };
    this.#insertWorktree(worktree);
    this.#reloadWorktrees();
    return worktree;
  }

  archiveWorktree(worktreeId: string): Worktree | null {
    const worktree = this.worktree(worktreeId);
    if (!worktree) {
      return null;
    }
    for (const pane of this.listPanes().filter((pane) => pane.worktreeId === worktreeId)) {
      this.closePane(pane.id);
    }
    this.#database.query("DELETE FROM worktrees WHERE id = $id").run({ $id: worktreeId });
    this.#reloadWorktrees();
    return { ...worktree, status: "archived", taskStatus: "done" };
  }

  removeRepository(repoId: string): boolean {
    const result = this.#database.query("DELETE FROM repos WHERE id = $id").run({ $id: repoId });
    this.#reloadRepositories();
    this.#reloadWorktrees();
    return result.changes > 0;
  }

  updateSettings(patch: Record<string, unknown>): SettingsSnapshot {
    const statement = this.#database.query(`
      INSERT INTO settings (key, value_json)
      VALUES ($key, $valueJson)
      ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json
    `);
    for (const [key, value] of Object.entries(patch)) {
      statement.run({ $key: key, $valueJson: JSON.stringify(value) });
    }
    return this.settingsSnapshot(Object.keys(patch));
  }

  #ensureSeedRepository(repoPath: string): void {
    const count = this.#database.query("SELECT COUNT(*) AS count FROM repos").get() as { count: number };
    if (count.count > 0) {
      return;
    }
    const repository: Repository = {
      id: "repo-default",
      path: repoPath,
      displayName: displayName(repoPath),
      color: "#0a84ff",
    };
    const worktree: Worktree = {
      id: "worktree-default",
      repoId: repository.id,
      path: repoPath,
      name: "default",
      branch: "main",
      status: "clean",
      taskStatus: "idle",
      unreadCount: 0,
    };
    this.#insertRepository(repository);
    this.#insertWorktree(worktree);
  }

  listPanes(): PaneDescriptor[] {
    return Array.from(this.#panes.values());
  }

  hasPane(paneId: string): boolean {
    return this.#panes.has(paneId);
  }

  paneForChannel(channelId: number): PaneDescriptor | null {
    const paneId = this.#paneIdByChannel.get(channelId);
    return paneId ? (this.#panes.get(paneId) ?? null) : null;
  }

  settingsSnapshot(keys?: string[]): SettingsSnapshot {
    const snapshot: SettingsSnapshot = {};
    if (!keys || keys.includes("panes")) {
      snapshot.panes = this.listPanes();
    }
    const rows = this.#database.query("SELECT key, value_json FROM settings").all() as SettingRow[];
    for (const row of rows) {
      if (!keys || keys.includes(row.key)) {
        snapshot[row.key] = JSON.parse(row.value_json);
      }
    }
    return snapshot;
  }

  listCustomActions(repoId?: string): CustomAction[] {
    const rows = repoId
      ? (this.#database
          .query(
            "SELECT id, repo_id, name, command, shortcut, icon, output_mode, ordering FROM custom_actions WHERE repo_id IS NULL OR repo_id = $repoId ORDER BY ordering, name",
          )
          .all({ $repoId: repoId }) as CustomActionRow[])
      : (this.#database
          .query(
            "SELECT id, repo_id, name, command, shortcut, icon, output_mode, ordering FROM custom_actions ORDER BY ordering, name",
          )
          .all() as CustomActionRow[]);
    return rows.map(actionFromRow);
  }

  customAction(actionId: string): CustomAction | null {
    const row = this.#database
      .query(
        "SELECT id, repo_id, name, command, shortcut, icon, output_mode, ordering FROM custom_actions WHERE id = $id",
      )
      .get({ $id: actionId }) as CustomActionRow | null;
    return row ? actionFromRow(row) : null;
  }

  upsertCustomAction(action: Omit<CustomAction, "id"> & { id?: string }): CustomAction {
    const next: CustomAction = {
      id: action.id || crypto.randomUUID(),
      repoId: action.repoId,
      name: action.name.trim(),
      command: action.command.trim(),
      shortcut: action.shortcut?.trim() || undefined,
      icon: action.icon?.trim() || undefined,
      outputMode: action.outputMode,
      ordering: action.ordering,
    };
    this.#database
      .query(`
        INSERT INTO custom_actions (id, repo_id, name, command, shortcut, icon, output_mode, ordering)
        VALUES ($id, $repoId, $name, $command, $shortcut, $icon, $outputMode, $ordering)
        ON CONFLICT(id) DO UPDATE SET
          repo_id = excluded.repo_id,
          name = excluded.name,
          command = excluded.command,
          shortcut = excluded.shortcut,
          icon = excluded.icon,
          output_mode = excluded.output_mode,
          ordering = excluded.ordering
      `)
      .run({
        $id: next.id,
        $repoId: next.repoId,
        $name: next.name,
        $command: next.command,
        $shortcut: next.shortcut ?? null,
        $icon: next.icon ?? null,
        $outputMode: next.outputMode,
        $ordering: next.ordering,
      });
    return next;
  }

  deleteCustomAction(actionId: string): boolean {
    const result = this.#database.query("DELETE FROM custom_actions WHERE id = $id").run({ $id: actionId });
    return result.changes > 0;
  }

  createPane(worktreeId: string, title = "Shell", command?: string, cwd?: string): PaneDescriptor {
    const pane: PaneDescriptor = {
      id: crypto.randomUUID(),
      channelId: this.#nextChannelId++,
      worktreeId,
      title,
      taskStatus: "idle",
      unread: false,
      lastOutputLine: "Daemon pane is ready",
      updatedAt: Date.now(),
    };
    this.#panes.set(pane.id, pane);
    this.#replayByPane.set(pane.id, new Uint8Array());
    this.#paneIdByChannel.set(pane.channelId, pane.id);
    if (this.#options.spawnProcesses) {
      this.#spawnRuntime(pane, command, cwd);
    }
    return pane;
  }

  closePane(paneId: string): boolean {
    const pane = this.#panes.get(paneId);
    const runtime = this.#runtimesByPane.get(paneId);
    runtime?.process.terminal?.close();
    runtime?.process.kill();
    this.#runtimesByPane.delete(paneId);
    this.#replayByPane.delete(paneId);
    if (pane) {
      this.#paneIdByChannel.delete(pane.channelId);
    }
    return this.#panes.delete(paneId);
  }

  replayForPane(paneId: string): Uint8Array | null {
    if (!this.#panes.has(paneId)) {
      return null;
    }
    return this.#replayByPane.get(paneId) ?? new Uint8Array();
  }

  writeToChannel(channelId: number, payload: Uint8Array): boolean {
    const paneId = this.#paneIdByChannel.get(channelId);
    if (!paneId) {
      return false;
    }
    const runtime = this.#runtimesByPane.get(paneId);
    if (!runtime) {
      return false;
    }
    runtime.process.terminal?.write(payload);
    return true;
  }

  resizePane(paneId: string, cols: number, rows: number): boolean {
    const runtime = this.#runtimesByPane.get(paneId);
    if (!runtime?.process.terminal) {
      return false;
    }
    runtime.process.terminal.resize(cols, rows);
    return true;
  }

  updatePaneStatus(paneId: string, taskStatus: PaneDescriptor["taskStatus"]): PaneDescriptor | null {
    const pane = this.#panes.get(paneId);
    if (!pane) {
      return null;
    }
    pane.taskStatus = taskStatus;
    pane.updatedAt = Date.now();
    return pane;
  }

  runCustomAction(paneId: string, actionId: string): RunCustomActionResult | null {
    const pane = this.#panes.get(paneId);
    const action = this.customAction(actionId);
    if (!pane || !action) {
      return null;
    }
    const sourceWorktree = this.#worktreeForPane(pane);
    if (action.repoId && sourceWorktree?.repoId !== action.repoId) {
      return null;
    }
    const targetPane = action.outputMode === "newPane" ? this.createPane(pane.worktreeId, action.name) : pane;
    const worktree = this.#worktreeForPane(targetPane);
    this.#recordPaneOutput(targetPane.id, new TextEncoder().encode(`\r\n$ ${action.command}\r\n`));
    const child = Bun.spawn([this.#options.shell, "-lc", action.command], {
      cwd: worktree?.path ?? process.cwd(),
      stdout: "pipe",
      stderr: "pipe",
      env: {
        ...process.env,
        TERM: "xterm-256color",
      },
    });
    void this.#pipeActionOutput(targetPane.id, child);
    return { action, pane: targetPane.id === pane.id ? undefined : targetPane };
  }

  async #pipeActionOutput(paneId: string, child: Bun.Subprocess<"ignore", "pipe", "pipe">): Promise<void> {
    await Promise.all([this.#readActionStream(paneId, child.stdout), this.#readActionStream(paneId, child.stderr)]);
    const exitCode = await child.exited;
    const pane = this.#panes.get(paneId);
    if (pane) {
      pane.taskStatus = exitCode === 0 ? "done" : "failed";
      pane.updatedAt = Date.now();
    }
  }

  async #readActionStream(paneId: string, stream: ReadableStream<Uint8Array>): Promise<void> {
    const reader = stream.getReader();
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          return;
        }
        this.#recordPaneOutput(paneId, value);
      }
    } finally {
      reader.releaseLock();
    }
  }

  #spawnRuntime(pane: PaneDescriptor, command?: string, cwd?: string): void {
    const worktree = this.#worktreeForPane(pane);
    const args = command ? ["-lc", command] : ["-i"];
    const child = this.#options.spawnPaneProcess({
      shell: this.#options.shell,
      args,
      cwd: cwd ?? worktree?.path ?? process.cwd(),
      onData: (data) => {
        this.#recordPaneOutput(pane.id, data);
      },
    });
    this.#runtimesByPane.set(pane.id, {
      process: child,
    });
    void child.exited.then((exitCode) => {
      const current = this.#panes.get(pane.id);
      if (current) {
        current.taskStatus = exitCode === 0 ? "done" : "failed";
        current.updatedAt = Date.now();
        this.#options.onPaneExit(pane.id, exitCode);
      }
      this.#runtimesByPane.delete(pane.id);
    });
  }

  #recordPaneOutput(paneId: string, data: Uint8Array): void {
    const pane = this.#panes.get(paneId);
    if (!pane) {
      return;
    }
    pane.lastOutputLine = lastNonEmptyLine(new TextDecoder().decode(data)) ?? pane.lastOutputLine;
    pane.updatedAt = Date.now();
    this.#appendReplay(paneId, data);
    this.#options.onPaneData(pane.channelId, data);
  }

  #appendReplay(paneId: string, data: Uint8Array): void {
    const current = this.#replayByPane.get(paneId) ?? new Uint8Array();
    const combined = new Uint8Array(Math.min(replayBufferBytes, current.byteLength + data.byteLength));
    const keepFromCurrent = Math.max(0, combined.byteLength - data.byteLength);
    if (keepFromCurrent > 0) {
      combined.set(current.subarray(current.byteLength - keepFromCurrent), 0);
    }
    combined.set(data.subarray(Math.max(0, data.byteLength - combined.byteLength)), keepFromCurrent);
    this.#replayByPane.set(paneId, combined);
  }

  #worktreeForPane(pane: PaneDescriptor): Worktree | undefined {
    for (const worktrees of this.worktreesByRepo.values()) {
      const worktree = worktrees.find((candidate) => candidate.id === pane.worktreeId);
      if (worktree) {
        return worktree;
      }
    }
  }

  #reloadRepositories(): void {
    const rows = this.#database
      .query("SELECT id, path, display_name, appearance_json FROM repos ORDER BY created_at")
      .all() as RepoRow[];
    this.repositories = rows.map((row) => {
      const appearance = safeJson(row.appearance_json);
      return {
        id: row.id,
        path: row.path,
        displayName: row.display_name ?? displayName(row.path),
        color: typeof appearance.color === "string" ? appearance.color : "#0a84ff",
      };
    });
  }

  #reloadWorktrees(): void {
    this.worktreesByRepo.clear();
    const rows = this.#database
      .query("SELECT id, repo_id, path, branch, status, task_status, metadata_json FROM worktrees ORDER BY created_at")
      .all() as WorktreeRow[];
    for (const row of rows) {
      const metadata = safeJson(row.metadata_json);
      const worktree: Worktree = {
        id: row.id,
        repoId: row.repo_id,
        path: row.path,
        name: typeof metadata.name === "string" ? metadata.name : displayName(row.path),
        branch: row.branch ?? "main",
        status: isWorktreeStatus(row.status) ? row.status : "clean",
        taskStatus: isTaskStatus(row.task_status) ? row.task_status : "idle",
        unreadCount: typeof metadata.unreadCount === "number" ? metadata.unreadCount : 0,
      };
      const current = this.worktreesByRepo.get(worktree.repoId) ?? [];
      this.worktreesByRepo.set(worktree.repoId, [...current, worktree]);
    }
  }

  #insertRepository(repository: Repository): void {
    this.#database
      .query(`
        INSERT INTO repos (id, path, display_name, appearance_json, created_at)
        VALUES ($id, $path, $displayName, $appearanceJson, $createdAt)
      `)
      .run({
        $id: repository.id,
        $path: repository.path,
        $displayName: repository.displayName,
        $appearanceJson: JSON.stringify({ color: repository.color }),
        $createdAt: Date.now(),
      });
  }

  #insertWorktree(worktree: Worktree): void {
    this.#database
      .query(`
        INSERT INTO worktrees (id, repo_id, path, branch, status, task_status, metadata_json, created_at)
        VALUES ($id, $repoId, $path, $branch, $status, $taskStatus, $metadataJson, $createdAt)
      `)
      .run({
        $id: worktree.id,
        $repoId: worktree.repoId,
        $path: worktree.path,
        $branch: worktree.branch,
        $status: worktree.status,
        $taskStatus: worktree.taskStatus,
        $metadataJson: JSON.stringify({ name: worktree.name, unreadCount: worktree.unreadCount }),
        $createdAt: Date.now(),
      });
  }
}

function lastNonEmptyLine(text: string): string | null {
  const lines = text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
  return lines.at(-1) ?? null;
}

function defaultStatePath(): string {
  return join(homedir(), ".prowl", "state.sqlite");
}

function spawnTerminalProcess(options: {
  shell: string;
  args: string[];
  cwd: string;
  onData: (data: Uint8Array) => void;
}): PaneProcess {
  return Bun.spawn([options.shell, ...options.args], {
    cwd: options.cwd,
    terminal: {
      cols: 120,
      rows: 32,
      data: (_terminal, data) => {
        options.onData(data);
      },
    },
    env: {
      ...process.env,
      TERM: "xterm-256color",
    },
  });
}

function openDatabase(path: string): Database {
  if (path !== ":memory:") {
    mkdirSync(dirname(path), { recursive: true });
  }
  return new Database(path);
}

function migrateDatabase(database: Database): void {
  for (const statement of [
    "ALTER TABLE custom_actions ADD COLUMN icon TEXT",
    "ALTER TABLE custom_actions ADD COLUMN output_mode TEXT NOT NULL DEFAULT 'currentPane'",
  ]) {
    try {
      database.exec(statement);
    } catch {
      // Column already exists.
    }
  }
}

function displayName(path: string): string {
  return path.split("/").filter(Boolean).at(-1) ?? "Repository";
}

function safeJson(raw: string | null): Record<string, unknown> {
  if (!raw) {
    return {};
  }
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function isWorktreeStatus(value: string | null): value is Worktree["status"] {
  return value === "clean" || value === "dirty" || value === "loading" || value === "archived";
}

function isTaskStatus(value: string | null): value is Worktree["taskStatus"] {
  return value === "idle" || value === "running" || value === "done" || value === "failed";
}

function actionFromRow(row: CustomActionRow): CustomAction {
  return {
    id: row.id,
    repoId: row.repo_id,
    name: row.name,
    command: row.command,
    shortcut: row.shortcut ?? undefined,
    icon: row.icon ?? undefined,
    outputMode: row.output_mode === "newPane" ? "newPane" : "currentPane",
    ordering: row.ordering,
  };
}
