import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { PaneDescriptor, Repository, SettingsSnapshot, Worktree } from "@prowl/protocol";
import { schemaSql } from "./schema";

type StateOptions = {
  spawnProcesses?: boolean;
  onPaneData?: (channelId: number, payload: Uint8Array) => void;
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

type PaneRuntime = {
  process: {
    kill: () => void;
    exited: Promise<number>;
    terminal?: {
      write: (payload: string | Uint8Array) => void;
      resize: (cols: number, rows: number) => void;
      close: () => void;
    };
  };
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
      onPaneData: options.onPaneData ?? (() => {}),
      shell: options.shell ?? "/bin/sh",
      statePath: options.statePath ?? defaultStatePath(),
    };
    this.#database = openDatabase(this.#options.statePath);
    this.#database.exec(schemaSql);
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

  createPane(worktreeId: string, title = "Shell", command?: string): PaneDescriptor {
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
      this.#spawnRuntime(pane, command);
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

  #spawnRuntime(pane: PaneDescriptor, command?: string): void {
    const worktree = this.#worktreeForPane(pane);
    const args = command ? ["-lc", command] : ["-i"];
    const child = Bun.spawn([this.#options.shell, ...args], {
      cwd: worktree?.path ?? process.cwd(),
      terminal: {
        cols: 120,
        rows: 32,
        data: (_terminal, data) => {
          this.#recordPaneOutput(pane.id, data);
        },
      },
      env: {
        ...process.env,
        TERM: "xterm-256color",
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

function openDatabase(path: string): Database {
  if (path !== ":memory:") {
    mkdirSync(dirname(path), { recursive: true });
  }
  return new Database(path);
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
