import { WSClient } from "$lib/ws/WSClient";
import type {
  CustomAction,
  PaneDescriptor,
  Repository,
  ServerControlMessage,
  Worktree,
  WorktreeDiff,
} from "@prowl/protocol";
import { makeMessageId, protocolVersion } from "@prowl/protocol";
import { get, set } from "idb-keyval";
import { Pane } from "./Pane";
import { WorktreeView } from "./WorktreeView";
import { defaultShortcuts, normalizeKeyChord } from "./shortcuts";
import type { ActionId, AppSettings, AppView, ConnectionState, PaletteItem } from "./types";

export const appStateKey = Symbol("ProwlAppState");

const uiViewKey = "prowl:ui.view";
const selectedWorktreeKey = "prowl:ui.selectedWorktreeId";
const appearanceSettingsKey = "prowl:settings.appearance";
const sessionTokenKey = "prowl:token";
const defaultDaemonURL = "ws://127.0.0.1:7878/ws";
const textDecoder = new TextDecoder();
const textEncoder = new TextEncoder();
const defaultSettings: AppSettings = {
  appearance: {
    theme: "system",
    terminalDensity: "comfortable",
    showUnreadBadges: true,
  },
  shortcuts: Object.fromEntries(defaultShortcuts),
  advanced: {
    performanceHUD: false,
    confirmDestructiveActions: true,
    replayBufferKiB: 64,
  },
};

export class AppState {
  readonly ws = new WSClient();
  #bootstrapPromise: Promise<void> | null = null;
  repositories = $state<Repository[]>([]);
  customActions = $state<CustomAction[]>([]);
  worktreesByRepo = $state<Map<string, Worktree[]>>(new Map());
  panes = $state<Map<string, Pane>>(new Map());
  worktreeViews = $state<Map<string, WorktreeView>>(new Map());
  selectedWorktreeId = $state<string | null>(null);
  selectedPaneId = $state<string | null>(null);
  view = $state<AppView>("shelf");
  repoBusy = $state(false);
  diffBusy = $state(false);
  diff = $state<WorktreeDiff | null>(null);
  paletteOpen = $state(false);
  paletteQuery = $state("");
  connection = $state<ConnectionState>("closed");
  errorMessage = $state<string | null>(null);
  sessionId = $state<string | null>(null);
  settings = $state<AppSettings>(structuredClone(defaultSettings));

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

    const actionItems = this.customActions.map((action) => ({
      id: `action:${action.id}`,
      title: action.name,
      subtitle: action.command,
      section: "Actions" as const,
      invoke: () => {
        void this.runCustomAction(action.id);
      },
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
      {
        id: "view:settings",
        title: "Open Settings",
        subtitle: "Manage repositories and preferences",
        section: "Settings" as const,
        invoke: () => this.setView("settings"),
      },
      {
        id: "view:diff",
        title: "Show Diff",
        subtitle: this.selectedWorktree?.name ?? "Selected worktree",
        section: "Actions" as const,
        invoke: () => {
          void this.showDiff();
        },
      },
      ...actionItems,
      ...tabItems,
      ...worktreeItems,
    ];
  }

  handleKeydown(event: KeyboardEvent): void {
    this.#requestNotificationPermission();
    const action = this.#shortcutMap().get(normalizeKeyChord(event));
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
      case "view.settings":
        this.setView("settings");
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

  async addRepository(path: string): Promise<void> {
    const normalizedPath = path.trim();
    if (!normalizedPath) {
      return;
    }
    this.repoBusy = true;
    this.errorMessage = null;
    try {
      await this.ws.request({
        v: 1,
        type: "repo.add",
        id: makeMessageId(),
        path: normalizedPath,
      });
    } catch (error) {
      this.errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      this.repoBusy = false;
    }
  }

  async removeRepository(repoId: string): Promise<void> {
    if (!repoId) {
      return;
    }
    if (!this.#confirmDestructiveAction("Remove this repository from Prowl?")) {
      return;
    }
    this.repoBusy = true;
    this.errorMessage = null;
    try {
      await this.ws.request({
        v: 1,
        type: "repo.remove",
        id: makeMessageId(),
        repoId,
      });
    } catch (error) {
      this.errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      this.repoBusy = false;
    }
  }

  async createWorktree(repoId: string, branch: string, directory?: string): Promise<void> {
    const normalizedBranch = branch.trim();
    if (!repoId || !normalizedBranch) {
      return;
    }
    this.repoBusy = true;
    this.errorMessage = null;
    try {
      await this.ws.request({
        v: 1,
        type: "worktree.create",
        id: makeMessageId(),
        repoId,
        branch: normalizedBranch,
        directory: directory?.trim() || undefined,
      });
    } catch (error) {
      this.errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      this.repoBusy = false;
    }
  }

  async archiveWorktree(worktreeId: string): Promise<void> {
    if (!worktreeId) {
      return;
    }
    if (!this.#confirmDestructiveAction("Archive this worktree?")) {
      return;
    }
    this.repoBusy = true;
    this.errorMessage = null;
    try {
      await this.ws.request({
        v: 1,
        type: "worktree.archive",
        id: makeMessageId(),
        worktreeId,
      });
    } catch (error) {
      this.errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      this.repoBusy = false;
    }
  }

  async saveCustomAction(action: Omit<CustomAction, "id"> & { id?: string }): Promise<void> {
    this.repoBusy = true;
    this.errorMessage = null;
    try {
      await this.ws.request({
        v: 1,
        type: "action.upsert",
        id: makeMessageId(),
        action,
      });
    } catch (error) {
      this.errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      this.repoBusy = false;
    }
  }

  async deleteCustomAction(actionId: string): Promise<void> {
    if (!this.#confirmDestructiveAction("Delete this custom action?")) {
      return;
    }
    this.repoBusy = true;
    this.errorMessage = null;
    try {
      await this.ws.request({
        v: 1,
        type: "action.delete",
        id: makeMessageId(),
        actionId,
      });
    } catch (error) {
      this.errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      this.repoBusy = false;
    }
  }

  async runCustomAction(actionId: string): Promise<void> {
    if (!this.selectedPaneId) {
      this.errorMessage = "Select a pane before running a custom action.";
      return;
    }
    try {
      await this.ws.request({
        v: 1,
        type: "action.run",
        id: makeMessageId(),
        paneId: this.selectedPaneId,
        actionId,
      });
    } catch (error) {
      this.errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  async updatePaneStatus(paneId: string, taskStatus: PaneDescriptor["taskStatus"]): Promise<void> {
    const pane = this.panes.get(paneId);
    if (!pane || pane.taskStatus === taskStatus) {
      return;
    }
    const previousStatus = pane.taskStatus;
    pane.taskStatus = taskStatus;
    pane.updatedAt = Date.now();
    try {
      await this.ws.request({
        v: 1,
        type: "pane.status",
        id: makeMessageId(),
        paneId,
        taskStatus,
      });
    } catch (error) {
      this.errorMessage = error instanceof Error ? error.message : String(error);
    }
    if (taskStatus === "done" && previousStatus !== "done" && pane.id !== this.selectedPaneId) {
      this.#notifyPaneDone(pane);
    }
  }

  async updateSettings(patch: Partial<AppSettings>): Promise<void> {
    this.errorMessage = null;
    try {
      const response = await this.ws.request({
        v: 1,
        type: "settings.set",
        id: makeMessageId(),
        patch,
      });
      if (response.type === "settings.snapshot") {
        this.#mergeSettings(response.settings);
      }
    } catch (error) {
      this.errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  async showDiff(worktreeId = this.selectedWorktreeId): Promise<void> {
    if (!worktreeId) {
      return;
    }
    this.diffBusy = true;
    this.errorMessage = null;
    try {
      const response = await this.ws.request({
        v: 1,
        type: "worktree.diff",
        id: makeMessageId(),
        worktreeId,
      });
      if (response.type === "worktree.diffed") {
        this.diff = response.diff;
        this.setView("diff");
      }
    } catch (error) {
      this.errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      this.diffBusy = false;
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
    const [view, selectedWorktreeId, appearance] = await Promise.all([
      get<AppView>(uiViewKey),
      get<string>(selectedWorktreeKey),
      get<AppSettings["appearance"]>(appearanceSettingsKey),
    ]);
    if (view === "shelf" || view === "canvas" || view === "settings" || view === "diff") {
      this.view = view;
    }
    if (appearance) {
      this.settings = { ...this.settings, appearance: { ...this.settings.appearance, ...appearance } };
      this.#applyAppearanceSettings();
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
      await this.ws.request({ v: 1, type: "action.list", id: makeMessageId() });
      for (const repository of this.repositories) {
        await this.ws.request({
          v: 1,
          type: "worktree.list",
          id: makeMessageId(),
          repoId: repository.id,
        });
      }
      await this.ws.request({
        v: 1,
        type: "settings.get",
        id: makeMessageId(),
        keys: ["appearance", "shortcuts", "advanced", "panes"],
      });
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
        this.#removeMissingRepositoryWorktrees(message.repositories);
        this.#ensureSelection();
        break;
      case "repo.updated":
        this.#upsertRepository(message.repository);
        break;
      case "action.listed":
        this.customActions = message.actions;
        break;
      case "action.updated":
        this.#upsertCustomAction(message.action);
        break;
      case "action.deleted":
        this.customActions = this.customActions.filter((action) => action.id !== message.actionId);
        break;
      case "worktree.listed":
        this.#replaceWorktrees(message.repoId, message.worktrees);
        break;
      case "worktree.updated":
        if (message.worktree.status === "archived") {
          this.#removeWorktree(message.worktree);
          break;
        }
        this.#upsertWorktree(message.worktree);
        break;
      case "worktree.diffed":
        this.diff = message.diff;
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
        this.#mergeSettings(message.settings);
        if (Array.isArray(message.settings.panes)) {
          this.#replacePanes(message.settings.panes as PaneDescriptor[]);
        }
        break;
      case "error":
        this.errorMessage = `${message.code}: ${message.message}`;
        break;
      case "notification":
        if (message.paneId) {
          const pane = this.panes.get(message.paneId);
          if (pane && pane.id !== this.selectedPaneId) {
            this.#notifyPaneDone(pane, message.body);
          }
        }
        this.errorMessage = null;
        break;
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

  #upsertCustomAction(action: CustomAction): void {
    const index = this.customActions.findIndex((candidate) => candidate.id === action.id);
    if (index === -1) {
      this.customActions = [...this.customActions, action];
      return;
    }
    this.customActions = this.customActions.with(index, action);
  }

  #replaceWorktrees(repoId: string, worktrees: Worktree[]): void {
    const next = new Map(this.worktreesByRepo);
    next.set(repoId, worktrees);
    this.worktreesByRepo = next;
    this.#ensureWorktreeViews(worktrees);
    this.#ensureSelection();
  }

  #removeMissingRepositoryWorktrees(repositories: Repository[]): void {
    const ids = new Set(repositories.map((repository) => repository.id));
    const next = new Map(this.worktreesByRepo);
    for (const repoId of next.keys()) {
      if (!ids.has(repoId)) {
        next.delete(repoId);
      }
    }
    this.worktreesByRepo = next;
  }

  #upsertWorktree(worktree: Worktree): void {
    const current = this.worktreesByRepo.get(worktree.repoId) ?? [];
    const index = current.findIndex((candidate) => candidate.id === worktree.id);
    const updated = index === -1 ? [...current, worktree] : current.with(index, worktree);
    this.#replaceWorktrees(worktree.repoId, updated);
  }

  #removeWorktree(worktree: Worktree): void {
    const current = this.worktreesByRepo.get(worktree.repoId) ?? [];
    this.#replaceWorktrees(
      worktree.repoId,
      current.filter((candidate) => candidate.id !== worktree.id),
    );
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

  #mergeSettings(snapshot: Record<string, unknown>): void {
    this.settings = {
      appearance: sanitizeAppearance(snapshot.appearance, this.settings.appearance),
      shortcuts: sanitizeShortcuts(snapshot.shortcuts, this.settings.shortcuts),
      advanced: sanitizeAdvanced(snapshot.advanced, this.settings.advanced),
    };
    void set(appearanceSettingsKey, this.settings.appearance);
    this.#applyAppearanceSettings();
  }

  #applyAppearanceSettings(): void {
    if (typeof document === "undefined") {
      return;
    }
    const theme = this.settings.appearance.theme;
    document.documentElement.dataset.theme = theme;
    document.documentElement.dataset.terminalDensity = this.settings.appearance.terminalDensity;
    document.documentElement.dataset.unreadBadges = String(this.settings.appearance.showUnreadBadges);
    document.documentElement.style.colorScheme = theme === "system" ? "light dark" : theme;
  }

  #shortcutMap(): Map<string, ActionId> {
    return new Map(
      Object.entries(this.settings.shortcuts)
        .filter((entry): entry is [ActionId, string] => Boolean(entry[1]?.trim()))
        .map(([action, chord]) => [chord.trim(), action]),
    );
  }

  #confirmDestructiveAction(message: string): boolean {
    if (!this.settings.advanced.confirmDestructiveActions || typeof window === "undefined") {
      return true;
    }
    return window.confirm(message);
  }

  #requestNotificationPermission(): void {
    if (typeof Notification === "undefined" || Notification.permission !== "default") {
      return;
    }
    void Notification.requestPermission();
  }

  #notifyPaneDone(pane: Pane, body = pane.lastOutputLine): void {
    if (typeof Notification === "undefined" || Notification.permission !== "granted") {
      return;
    }
    new Notification(pane.title, {
      body: lastNonEmptyLine(body),
      tag: `prowl-pane-${pane.id}`,
    });
    void new Audio("/notification.wav").play().catch(() => {});
  }
}

export function createAppState(): AppState {
  return new AppState();
}

function lastNonEmptyLine(text: string): string {
  return (
    text
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)
      .at(-1) ?? ""
  );
}

function sanitizeAppearance(value: unknown, fallback: AppSettings["appearance"]): AppSettings["appearance"] {
  if (!isRecord(value)) {
    return fallback;
  }
  const theme =
    value.theme === "light" || value.theme === "dark" || value.theme === "system" ? value.theme : fallback.theme;
  const terminalDensity =
    value.terminalDensity === "compact" || value.terminalDensity === "comfortable"
      ? value.terminalDensity
      : fallback.terminalDensity;
  const showUnreadBadges =
    typeof value.showUnreadBadges === "boolean" ? value.showUnreadBadges : fallback.showUnreadBadges;
  return { theme, terminalDensity, showUnreadBadges };
}

function sanitizeShortcuts(value: unknown, fallback: AppSettings["shortcuts"]): AppSettings["shortcuts"] {
  if (!isRecord(value)) {
    return fallback;
  }
  const shortcuts: AppSettings["shortcuts"] = { ...defaultSettings.shortcuts };
  for (const action of Object.keys(defaultSettings.shortcuts) as ActionId[]) {
    const chord = value[action];
    shortcuts[action] = typeof chord === "string" ? chord : fallback[action];
  }
  return shortcuts;
}

function sanitizeAdvanced(value: unknown, fallback: AppSettings["advanced"]): AppSettings["advanced"] {
  if (!isRecord(value)) {
    return fallback;
  }
  const replayBufferKiB = typeof value.replayBufferKiB === "number" ? value.replayBufferKiB : fallback.replayBufferKiB;
  return {
    performanceHUD: typeof value.performanceHUD === "boolean" ? value.performanceHUD : fallback.performanceHUD,
    confirmDestructiveActions:
      typeof value.confirmDestructiveActions === "boolean"
        ? value.confirmDestructiveActions
        : fallback.confirmDestructiveActions,
    replayBufferKiB: Math.min(Math.max(Math.round(replayBufferKiB), 16), 1024),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
