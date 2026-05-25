import { WSClient } from "$lib/ws/WSClient";
import type { PaneDescriptor, Repository, ServerControlMessage, Worktree } from "@prowl/protocol";
import { makeMessageId, protocolVersion } from "@prowl/protocol";
import { get, set } from "idb-keyval";
import { Pane } from "./Pane";
import { WorktreeView } from "./WorktreeView";
import { normalizeKeyChord, shortcuts } from "./shortcuts";
import type { ActionId, AppView, ConnectionState, PaletteItem } from "./types";

export const appStateKey = Symbol("ProwlAppState");

const uiViewKey = "prowl:ui.view";
const selectedWorktreeKey = "prowl:ui.selectedWorktreeId";
const sessionTokenKey = "prowl:token";
const defaultDaemonURL = "ws://127.0.0.1:7878/ws";
const textDecoder = new TextDecoder();
const textEncoder = new TextEncoder();

export class AppState {
  readonly ws = new WSClient();
  #bootstrapPromise: Promise<void> | null = null;
  repositories = $state<Repository[]>([]);
  worktreesByRepo = $state<Map<string, Worktree[]>>(new Map());
  panes = $state<Map<string, Pane>>(new Map());
  worktreeViews = $state<Map<string, WorktreeView>>(new Map());
  selectedWorktreeId = $state<string | null>(null);
  selectedPaneId = $state<string | null>(null);
  view = $state<AppView>("shelf");
  paletteOpen = $state(false);
  paletteQuery = $state("");
  connection = $state<ConnectionState>("closed");
  errorMessage = $state<string | null>(null);
  sessionId = $state<string | null>(null);

  constructor() {
    if (typeof window === "undefined") {
      return;
    }
    this.ws.onStatus((connection) => {
      this.connection = connection;
    });
    this.ws.onMessage((message) => this.#handleServerMessage(message));
    this.ws.onBinary((channelId, payload) => this.#handlePaneOutput(channelId, payload));
    this.#restoreUIState();
    this.#connectFromLocation();
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
        void this.createPane();
        break;
      case "pane.close":
        void this.closeSelectedPane();
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

  async createPane(): Promise<void> {
    const worktreeId = this.selectedWorktreeId ?? this.worktrees[0]?.id;
    if (!worktreeId) {
      return;
    }

    try {
      await this.ws.request({
        v: 1,
        type: "pane.create",
        id: makeMessageId(),
        worktreeId,
        cols: 120,
        rows: 32,
      });
    } catch (error) {
      this.errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  async closeSelectedPane(): Promise<void> {
    if (!this.selectedPaneId) {
      return;
    }
    try {
      await this.ws.request({
        v: 1,
        type: "pane.close",
        id: makeMessageId(),
        paneId: this.selectedPaneId,
      });
    } catch (error) {
      this.errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  sendInputToSelectedPane(text: string): void {
    const pane = this.selectedPane;
    if (!pane) {
      return;
    }
    this.ws.sendBinary(pane.channelId, textEncoder.encode(text));
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

  #connectFromLocation(): void {
    const url = new URL(window.location.href);
    const tokenFromURL = url.searchParams.get("token");
    if (tokenFromURL) {
      sessionStorage.setItem(sessionTokenKey, tokenFromURL);
      url.searchParams.delete("token");
      window.history.replaceState({}, "", url);
    }

    const token = tokenFromURL ?? sessionStorage.getItem(sessionTokenKey) ?? "";
    const daemonURL = new URL(url.searchParams.get("daemon") ?? defaultDaemonURL);
    if (token) {
      daemonURL.searchParams.set("token", token);
    }

    this.ws.connect(daemonURL.toString());
    this.ws.onStatus((state) => {
      if (state === "open") {
        void this.#bootstrapOnce(token);
      }
    });
  }

  #bootstrapOnce(token: string): Promise<void> {
    this.#bootstrapPromise ??= this.#bootstrap(token).finally(() => {
      this.#bootstrapPromise = null;
    });
    return this.#bootstrapPromise;
  }

  async #bootstrap(token: string): Promise<void> {
    try {
      await this.ws.request({
        v: 1,
        type: "hello",
        id: makeMessageId(),
        token,
        clientVersion: "0.0.0",
        protocolVersion,
      });
      await this.ws.request({ v: 1, type: "repo.list", id: makeMessageId() });
      for (const repository of this.repositories) {
        await this.ws.request({
          v: 1,
          type: "worktree.list",
          id: makeMessageId(),
          repoId: repository.id,
        });
      }
      await this.ws.request({ v: 1, type: "settings.get", id: makeMessageId(), keys: ["panes"] });
      await this.#attachExistingPanes();
    } catch (error) {
      this.errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  #handleServerMessage(message: ServerControlMessage): void {
    switch (message.type) {
      case "welcome":
        this.sessionId = message.sessionId;
        this.errorMessage = null;
        break;
      case "repo.listed":
        this.repositories = message.repositories;
        break;
      case "repo.updated":
        this.#upsertRepository(message.repository);
        break;
      case "worktree.listed":
        this.#replaceWorktrees(message.repoId, message.worktrees);
        break;
      case "worktree.updated":
        this.#upsertWorktree(message.worktree);
        break;
      case "pane.listed":
        this.#replacePanes(message.panes);
        break;
      case "pane.created":
        this.#upsertPane({
          id: message.paneId,
          channelId: message.channelId,
          worktreeId: message.worktreeId,
          title: message.title ?? "Shell",
          taskStatus: "idle",
          unread: false,
          lastOutputLine: "Connected to daemon-backed pane",
          updatedAt: Date.now(),
        });
        this.selectedPaneId = message.paneId;
        this.selectedWorktreeId = message.worktreeId;
        break;
      case "pane.exited":
        this.#removePane(message.paneId);
        break;
      case "pane.replay":
        this.#applyPaneReplay(message.paneId, message.bytes);
        break;
      case "settings.snapshot":
        if (Array.isArray(message.settings.panes)) {
          this.#replacePanes(message.settings.panes as PaneDescriptor[]);
        }
        break;
      case "error":
        this.errorMessage = `${message.code}: ${message.message}`;
        break;
      case "notification":
      case "pane.resized":
      case "pong":
        break;
    }
  }

  #handlePaneOutput(channelId: number, payload: Uint8Array): void {
    const pane = Array.from(this.panes.values()).find((candidate) => candidate.channelId === channelId);
    if (!pane) {
      return;
    }
    const text = textDecoder.decode(payload, { stream: true });
    pane.lastOutputLine = `${pane.lastOutputLine}${text}`;
    pane.updatedAt = Date.now();
    pane.unread = pane.id !== this.selectedPaneId;
  }

  async #attachExistingPanes(): Promise<void> {
    const panes = Array.from(this.panes.values());
    for (const pane of panes) {
      await this.ws.request({
        v: 1,
        type: "pane.attach",
        id: makeMessageId(),
        paneId: pane.id,
      });
    }
  }

  #applyPaneReplay(paneId: string, base64: string): void {
    const pane = this.panes.get(paneId);
    if (!pane) {
      return;
    }
    const binary = atob(base64);
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    pane.lastOutputLine = textDecoder.decode(bytes);
    pane.updatedAt = Date.now();
  }

  #upsertRepository(repository: Repository): void {
    const index = this.repositories.findIndex((candidate) => candidate.id === repository.id);
    if (index === -1) {
      this.repositories = [...this.repositories, repository];
      return;
    }
    this.repositories = this.repositories.with(index, repository);
  }

  #replaceWorktrees(repoId: string, worktrees: Worktree[]): void {
    const next = new Map(this.worktreesByRepo);
    next.set(repoId, worktrees);
    this.worktreesByRepo = next;
    this.#ensureWorktreeViews(worktrees);
    this.#ensureSelection();
  }

  #upsertWorktree(worktree: Worktree): void {
    const current = this.worktreesByRepo.get(worktree.repoId) ?? [];
    const index = current.findIndex((candidate) => candidate.id === worktree.id);
    const updated = index === -1 ? [...current, worktree] : current.with(index, worktree);
    this.#replaceWorktrees(worktree.repoId, updated);
  }

  #ensureWorktreeViews(worktrees: Worktree[]): void {
    const next = new Map(this.worktreeViews);
    for (const worktree of worktrees) {
      if (!next.has(worktree.id)) {
        next.set(worktree.id, new WorktreeView(worktree.id));
      }
    }
    this.worktreeViews = next;
  }

  #replacePanes(panes: PaneDescriptor[]): void {
    this.panes = new Map(panes.map((pane) => [pane.id, new Pane(pane)]));
    this.#ensureSelection();
  }

  #upsertPane(descriptor: PaneDescriptor): void {
    const next = new Map(this.panes);
    next.set(descriptor.id, new Pane(descriptor));
    this.panes = next;
  }

  #removePane(paneId: string): void {
    const next = new Map(this.panes);
    next.delete(paneId);
    this.panes = next;
    this.#ensureSelection();
  }

  #ensureSelection(): void {
    if (!this.selectedWorktreeId || !this.worktrees.some((worktree) => worktree.id === this.selectedWorktreeId)) {
      this.selectedWorktreeId = this.worktrees[0]?.id ?? null;
    }
    if (!this.selectedPaneId || !this.panes.has(this.selectedPaneId)) {
      this.selectedPaneId =
        Array.from(this.panes.values()).find((pane) => pane.worktreeId === this.selectedWorktreeId)?.id ?? null;
    }
  }
}

export function createAppState(): AppState {
  return new AppState();
}
