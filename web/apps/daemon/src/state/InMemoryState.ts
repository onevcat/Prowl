import type { PaneDescriptor, Repository, SettingsSnapshot, Worktree } from "@prowl/protocol";

export class InMemoryState {
  readonly repositories: Repository[];
  readonly worktreesByRepo = new Map<string, Worktree[]>();
  #panes = new Map<string, PaneDescriptor>();
  #nextChannelId = 1;

  constructor(repoPath = process.cwd()) {
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

  createPane(worktreeId: string, title = "Shell"): PaneDescriptor {
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
    return pane;
  }

  closePane(paneId: string): boolean {
    return this.#panes.delete(paneId);
  }
}
