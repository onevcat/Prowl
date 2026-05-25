import type { PaneDescriptor, Repository, SettingsSnapshot, Worktree } from "@prowl/protocol";

type StateOptions = {
  spawnProcesses?: boolean;
  onPaneData?: (channelId: number, payload: Uint8Array) => void;
  shell?: string;
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
  readonly repositories: Repository[];
  readonly worktreesByRepo = new Map<string, Worktree[]>();
  #panes = new Map<string, PaneDescriptor>();
  #runtimesByPane = new Map<string, PaneRuntime>();
  #paneIdByChannel = new Map<number, string>();
  #nextChannelId = 1;
  #options: Required<StateOptions>;

  constructor(repoPath = process.cwd(), options: StateOptions = {}) {
    this.#options = {
      spawnProcesses: options.spawnProcesses ?? true,
      onPaneData: options.onPaneData ?? (() => {}),
      shell: options.shell ?? "/bin/sh",
    };
    const repository: Repository = {
      id: "repo-default",
      path: repoPath,
      displayName: repoPath.split("/").filter(Boolean).at(-1) ?? "Repository",
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
    this.repositories = [repository];
    this.worktreesByRepo.set(repository.id, [worktree]);
    this.createPane(worktree.id, "Shell");
  }

  listPanes(): PaneDescriptor[] {
    return Array.from(this.#panes.values());
  }

  settingsSnapshot(keys?: string[]): SettingsSnapshot {
    const snapshot: SettingsSnapshot = {};
    if (!keys || keys.includes("panes")) {
      snapshot.panes = this.listPanes();
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
    if (pane) {
      this.#paneIdByChannel.delete(pane.channelId);
    }
    return this.#panes.delete(paneId);
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
    this.#options.onPaneData(pane.channelId, data);
  }

  #worktreeForPane(pane: PaneDescriptor): Worktree | undefined {
    for (const worktrees of this.worktreesByRepo.values()) {
      const worktree = worktrees.find((candidate) => candidate.id === pane.worktreeId);
      if (worktree) {
        return worktree;
      }
    }
  }
}

function lastNonEmptyLine(text: string): string | null {
  const lines = text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
  return lines.at(-1) ?? null;
}
