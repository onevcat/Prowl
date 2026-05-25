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
  };
  stdin: {
    write: (payload: Uint8Array) => number | Promise<number>;
    flush?: () => number | Promise<number>;
    end?: () => void;
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
    runtime?.stdin.end?.();
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
    void runtime.stdin.write(payload);
    void runtime.stdin.flush?.();
    return true;
  }

  #spawnRuntime(pane: PaneDescriptor, command?: string): void {
    const worktree = this.#worktreeForPane(pane);
    const args = command ? ["-lc", command] : ["-i"];
    const child = Bun.spawn([this.#options.shell, ...args], {
      cwd: worktree?.path ?? process.cwd(),
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
      env: {
        ...process.env,
        TERM: "xterm-256color",
      },
    });
    this.#runtimesByPane.set(pane.id, {
      process: child,
      stdin: child.stdin,
    });
    void this.#pumpOutput(pane.id, child.stdout);
    void this.#pumpOutput(pane.id, child.stderr);
    void child.exited.then((exitCode) => {
      const current = this.#panes.get(pane.id);
      if (current) {
        current.taskStatus = exitCode === 0 ? "done" : "failed";
        current.updatedAt = Date.now();
      }
      this.#runtimesByPane.delete(pane.id);
    });
  }

  async #pumpOutput(paneId: string, stream: ReadableStream<Uint8Array>): Promise<void> {
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }
        const pane = this.#panes.get(paneId);
        if (!pane) {
          break;
        }
        pane.lastOutputLine = lastNonEmptyLine(decoder.decode(value, { stream: true })) ?? pane.lastOutputLine;
        pane.updatedAt = Date.now();
        this.#options.onPaneData(pane.channelId, value);
      }
    } finally {
      reader.releaseLock();
    }
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
