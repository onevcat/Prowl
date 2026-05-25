import type { PaneDescriptor, Repository, Worktree } from "@prowl/protocol";
import { get, set } from "idb-keyval";
import { Pane } from "./Pane";
import { WorktreeView } from "./WorktreeView";
import { normalizeKeyChord, shortcuts } from "./shortcuts";
import type { ActionId, AppView, ConnectionState, PaletteItem } from "./types";

export const appStateKey = Symbol("ProwlAppState");

const uiViewKey = "prowl:ui.view";
const selectedWorktreeKey = "prowl:ui.selectedWorktreeId";

const demoRepositories: Repository[] = [
  {
    id: "repo-prowl",
    path: "/home/bubu/Prowl",
    displayName: "Prowl",
    color: "#0a84ff",
  },
];

const demoWorktrees: Worktree[] = [
  {
    id: "wt-main",
    repoId: "repo-prowl",
    path: "/home/bubu/Prowl",
    name: "main",
    branch: "main",
    status: "dirty",
    taskStatus: "running",
    unreadCount: 1,
  },
  {
    id: "wt-web",
    repoId: "repo-prowl",
    path: "/home/bubu/Prowl-web",
    name: "web-sveltekit-implementation",
    branch: "web-sveltekit-implementation",
    status: "loading",
    taskStatus: "idle",
    unreadCount: 0,
  },
];

const demoPanes: PaneDescriptor[] = [
  {
    id: "pane-main-1",
    channelId: 1,
    worktreeId: "wt-main",
    title: "Codex",
    taskStatus: "running",
    unread: true,
    lastOutputLine: "Implementing web workspace scaffold",
    updatedAt: Date.now() - 40_000,
  },
  {
    id: "pane-main-2",
    channelId: 2,
    worktreeId: "wt-main",
    title: "Tests",
    taskStatus: "idle",
    unread: false,
    lastOutputLine: "bun test",
    updatedAt: Date.now() - 300_000,
  },
  {
    id: "pane-web-1",
    channelId: 3,
    worktreeId: "wt-web",
    title: "Daemon",
    taskStatus: "idle",
    unread: false,
    lastOutputLine: "prowld --port 7878",
    updatedAt: Date.now() - 120_000,
  },
];

export class AppState {
  repositories = $state<Repository[]>(demoRepositories);
  worktreesByRepo = $state<Map<string, Worktree[]>>(new Map([["repo-prowl", demoWorktrees]]));
  panes = $state<Map<string, Pane>>(new Map(demoPanes.map((pane) => [pane.id, new Pane(pane)])));
  worktreeViews = $state<Map<string, WorktreeView>>(new Map());
  selectedWorktreeId = $state<string | null>("wt-main");
  selectedPaneId = $state<string | null>("pane-main-1");
  view = $state<AppView>("shelf");
  paletteOpen = $state(false);
  paletteQuery = $state("");
  connection = $state<ConnectionState>("closed");

  constructor() {
    for (const worktree of demoWorktrees) {
      this.worktreeViews.set(worktree.id, new WorktreeView(worktree.id));
    }
    this.#restoreUIState();
  }

  get worktrees(): Worktree[] {
    return Array.from(this.worktreesByRepo.values()).flat();
  }

  get selectedWorktree(): Worktree | null {
    return this.worktrees.find((worktree) => worktree.id === this.selectedWorktreeId) ?? null;
  }

  get selectedPane(): Pane | null {
    return this.selectedPaneId ? (this.panes.get(this.selectedPaneId) ?? null) : null;
  }

  get visiblePanes(): Pane[] {
    if (this.view === "canvas") {
      return Array.from(this.panes.values());
    }
    return Array.from(this.panes.values()).filter((pane) => pane.worktreeId === this.selectedWorktreeId);
  }

  get paletteItems(): PaletteItem[] {
    const tabItems = Array.from(this.panes.values()).map((pane) => ({
      id: `pane:${pane.id}`,
      title: pane.title,
      subtitle: pane.lastOutputLine,
      section: "Tabs" as const,
      invoke: () => this.selectPane(pane.id),
    }));

    const worktreeItems = this.worktrees.map((worktree) => ({
      id: `worktree:${worktree.id}`,
      title: worktree.name,
      subtitle: worktree.branch,
      section: "Worktrees" as const,
      invoke: () => this.selectWorktree(worktree.id),
    }));

    return [
      {
        id: "view:shelf",
        title: "Show Shelf",
        subtitle: "Switch to vertical worktree tabs",
        section: "Actions" as const,
        invoke: () => this.setView("shelf"),
      },
      {
        id: "view:canvas",
        title: "Show Canvas",
        subtitle: "Bird's-eye terminal grid",
        section: "Actions" as const,
        invoke: () => this.setView("canvas"),
      },
      ...tabItems,
      ...worktreeItems,
    ];
  }

  handleKeydown(event: KeyboardEvent): void {
    const action = shortcuts.get(normalizeKeyChord(event));
    if (!action) {
      return;
    }

    event.preventDefault();
    this.perform(action);
  }

  perform(action: ActionId): void {
    switch (action) {
      case "view.shelf":
        this.setView("shelf");
        break;
      case "view.canvas":
        this.setView("canvas");
        break;
      case "palette.open":
        this.paletteOpen = true;
        break;
      case "palette.close":
        this.paletteOpen = false;
        this.paletteQuery = "";
        break;
      case "pane.new":
        this.createPane();
        break;
      case "pane.close":
        this.closeSelectedPane();
        break;
      case "worktree.next":
        this.cycleWorktree(1);
        break;
      case "worktree.previous":
        this.cycleWorktree(-1);
        break;
      case "tab.next":
        this.cyclePane(1);
        break;
      case "tab.previous":
        this.cyclePane(-1);
        break;
    }
  }

  setView(view: AppView): void {
    this.view = view;
    void set(uiViewKey, view);
  }

  selectWorktree(worktreeId: string): void {
    this.selectedWorktreeId = worktreeId;
    const firstPane = Array.from(this.panes.values()).find((pane) => pane.worktreeId === worktreeId);
    this.selectedPaneId = firstPane?.id ?? null;
    void set(selectedWorktreeKey, worktreeId);
  }

  selectPane(paneId: string): void {
    const pane = this.panes.get(paneId);
    if (!pane) {
      return;
    }
    pane.unread = false;
    this.selectedPaneId = paneId;
    this.selectedWorktreeId = pane.worktreeId;
    this.paletteOpen = false;
  }

  createPane(): void {
    const worktreeId = this.selectedWorktreeId ?? this.worktrees[0]?.id;
    if (!worktreeId) {
      return;
    }

    const descriptor: PaneDescriptor = {
      id: crypto.randomUUID(),
      channelId: this.panes.size + 1,
      worktreeId,
      title: "New terminal",
      taskStatus: "idle",
      unread: false,
      lastOutputLine: "Waiting for daemon-backed PTY",
      updatedAt: Date.now(),
    };
    const next = new Map(this.panes);
    next.set(descriptor.id, new Pane(descriptor));
    this.panes = next;
    this.selectedPaneId = descriptor.id;
  }

  closeSelectedPane(): void {
    if (!this.selectedPaneId) {
      return;
    }
    const closing = this.selectedPaneId;
    const next = new Map(this.panes);
    next.delete(closing);
    this.panes = next;
    this.selectedPaneId =
      Array.from(next.values()).find((pane) => pane.worktreeId === this.selectedWorktreeId)?.id ?? null;
  }

  cycleWorktree(direction: 1 | -1): void {
    const worktrees = this.worktrees;
    if (!this.selectedWorktreeId || worktrees.length === 0) {
      return;
    }
    const currentIndex = worktrees.findIndex((worktree) => worktree.id === this.selectedWorktreeId);
    const nextIndex = (currentIndex + direction + worktrees.length) % worktrees.length;
    const nextWorktree = worktrees[nextIndex];
    if (nextWorktree) {
      this.selectWorktree(nextWorktree.id);
    }
  }

  cyclePane(direction: 1 | -1): void {
    const panes = Array.from(this.panes.values()).filter((pane) => pane.worktreeId === this.selectedWorktreeId);
    if (!this.selectedPaneId || panes.length === 0) {
      return;
    }
    const currentIndex = panes.findIndex((pane) => pane.id === this.selectedPaneId);
    const nextIndex = (currentIndex + direction + panes.length) % panes.length;
    const nextPane = panes[nextIndex];
    if (nextPane) {
      this.selectPane(nextPane.id);
    }
  }

  async #restoreUIState(): Promise<void> {
    const [view, selectedWorktreeId] = await Promise.all([get<AppView>(uiViewKey), get<string>(selectedWorktreeKey)]);
    if (view === "shelf" || view === "canvas") {
      this.view = view;
    }
    if (selectedWorktreeId && this.worktrees.some((worktree) => worktree.id === selectedWorktreeId)) {
      this.selectWorktree(selectedWorktreeId);
    }
  }
}

export function createAppState(): AppState {
  return new AppState();
}
