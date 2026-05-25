import { NotificationPermissionRequester } from "$lib/notifications/permission";
import { RendererPool } from "$lib/terminal/RendererPool";
import { inferAgentTaskStatus } from "$lib/terminal/detectAgent";
import { appendTerminalOutput, lastNonEmptyLine, terminalOutputSnapshot } from "$lib/terminal/outputBuffer";
import { ProtocolError, WSClient } from "$lib/ws/WSClient";
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
import { Pane } from "./Pane.svelte";
import { WorktreeView } from "./WorktreeView.svelte";
import { defaultShortcuts, normalizeKeyChord, shouldHandleGlobalShortcut } from "./shortcuts";
import type {
  ActionId,
  AppSettings,
  AppView,
  ConnectionState,
  PaletteHistoryEntry,
  PaletteItem,
  PerformanceMetrics,
} from "./types";

export const appStateKey = Symbol("ProwlAppState");

const uiViewKey = "prowl:ui.view";
const selectedWorktreeKey = "prowl:ui.selectedWorktreeId";
const worktreeOrderKey = "prowl:ui.worktreeOrderByRepo";
const paneOrderKey = "prowl:ui.paneOrderByWorktree";
const paletteHistoryKey = "prowl:palette.history";
const appearanceSettingsKey = "prowl:settings.appearance";
const sessionTokenKey = "prowl:token";
const defaultDaemonURL = "ws://127.0.0.1:7878/ws";
const textEncoder = new TextEncoder();
const maxMetricSamples = 100;
const settingsSections = [
  {
    id: "repositories",
    title: "Repositories",
    subtitle: "Manage registered repos and worktrees",
  },
  {
    id: "custom-actions",
    title: "Custom Actions",
    subtitle: "Create and edit user-defined commands",
  },
  {
    id: "appearance",
    title: "Appearance",
    subtitle: "Theme and terminal presentation",
  },
  {
    id: "shortcuts",
    title: "Shortcuts",
    subtitle: "Keyboard command bindings",
  },
  {
    id: "advanced",
    title: "Advanced",
    subtitle: "Debug and daemon-facing options",
  },
  {
    id: "updates",
    title: "Updates",
    subtitle: "Reload the web client",
  },
] as const;
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
  readonly rendererPool = new RendererPool();
  readonly #notificationPermission = new NotificationPermissionRequester();
  #bootstrapPromise: Promise<void> | null = null;
  #metricTimer: ReturnType<typeof setInterval> | null = null;
  #inputStartedByChannel = new Map<number, number>();
  #decoderByChannel = new Map<number, TextDecoder>();
  #paneSizeById = new Map<string, { cols: number; rows: number }>();
  #renderedPaneIds = new Set<string>();
  #paneIdsToResume = new Set<string>();
  #authToken = "";
  repositories = $state<Repository[]>([]);
  customActions = $state<CustomAction[]>([]);
  worktreesByRepo = $state<Map<string, Worktree[]>>(new Map());
  panes = $state<Map<string, Pane>>(new Map());
  worktreeOrderByRepo = $state<Record<string, string[]>>({});
  paneOrderByWorktree = $state<Record<string, string[]>>({});
  worktreeViews = $state<Map<string, WorktreeView>>(new Map());
  selectedWorktreeId = $state<string | null>(null);
  selectedPaneId = $state<string | null>(null);
  view = $state<AppView>("shelf");
  repoBusy = $state(false);
  diffBusy = $state(false);
  diff = $state<WorktreeDiff | null>(null);
  paletteOpen = $state(false);
  paletteQuery = $state("");
  paletteHistory = $state<PaletteHistoryEntry[]>([]);
  renderablePaneIds = $state<Set<string>>(new Set());
  connection = $state<ConnectionState>("closed");
  terminalBuffering = $state(false);
  errorMessage = $state<string | null>(null);
  sessionId = $state<string | null>(null);
  daemonURL = $state(defaultDaemonURL);
  loginToken = $state("");
  loginBusy = $state(false);
  loginError = $state<string | null>(null);
  settings = $state<AppSettings>(structuredClone(defaultSettings));
  metrics = $state<PerformanceMetrics>({
    inputLatencySamples: [],
    wsRttSamples: [],
    lastWsRtt: null,
  });

  constructor() {
    if (typeof window === "undefined") {
      return;
    }
    this.ws.onStatus((connection) => {
      this.connection = connection;
    });
    this.ws.onMessage((message) => this.#handleServerMessage(message));
    this.ws.onBinary((channelId, payload) => this.#handlePaneOutput(channelId, payload));
    this.ws.onBackpressure((buffering) => {
      this.terminalBuffering = buffering;
    });
    this.#restoreUIState();
    this.#connectFromLocation();
    this.#startMetricLoop();
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

  get runnableCustomActions(): CustomAction[] {
    const repoId = this.selectedWorktree?.repoId;
    return this.customActions.filter((action) => !action.repoId || action.repoId === repoId);
  }

  get visiblePanes(): Pane[] {
    if (this.view === "canvas") {
      return Array.from(this.panes.values());
    }
    return this.selectedWorktreeId ? this.orderedPanes(this.selectedWorktreeId) : [];
  }

  get activeRendererCount(): number {
    return this.renderablePaneIds.size;
  }

  get needsAuthentication(): boolean {
    return !this.sessionId && (this.connection !== "open" || this.errorMessage !== null);
  }

  orderedWorktrees(repoId: string): Worktree[] {
    return orderByIds(
      this.worktreesByRepo.get(repoId) ?? [],
      this.worktreeOrderByRepo[repoId],
      (worktree) => worktree.id,
    );
  }

  orderedPanes(worktreeId: string): Pane[] {
    return orderByIds(
      Array.from(this.panes.values()).filter((pane) => pane.worktreeId === worktreeId),
      this.paneOrderByWorktree[worktreeId],
      (pane) => pane.id,
    );
  }

  get paletteItems(): PaletteItem[] {
    const baseItems = this.#basePaletteItems();
    const baseIds = new Set(baseItems.map((item) => item.id));
    const recentItems = this.paletteHistory
      .filter((entry) => baseIds.has(entry.id))
      .map((entry) => ({
        id: `recent:${entry.id}`,
        sourceId: entry.id,
        title: entry.title,
        subtitle: entry.subtitle,
        section: "Recent" as const,
        invoke: () => {
          baseItems.find((item) => item.id === entry.id)?.invoke();
        },
      }));

    return [...recentItems, ...baseItems];
  }

  handleKeydown(event: KeyboardEvent): void {
    if (!shouldHandleGlobalShortcut(event)) {
      return;
    }
    this.requestNotificationPermission();
    const chord = normalizeKeyChord(event);
    const action = this.#shortcutMap().get(chord);
    if (action) {
      event.preventDefault();
      this.perform(action);
      return;
    }

    const customAction = this.customActions.find((candidate) => candidate.shortcut?.trim() === chord);
    if (customAction) {
      event.preventDefault();
      void this.runCustomAction(customAction.id);
    }
  }

  registerFirstUserGestureNotifications(target: EventTarget = window): () => void {
    return this.#notificationPermission.registerFirstGesture(target);
  }

  requestNotificationPermission(): void {
    this.#notificationPermission.request();
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
      case "performance.toggle":
        void this.updateSettings({
          advanced: {
            ...this.settings.advanced,
            performanceHUD: !this.settings.advanced.performanceHUD,
          },
        });
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

  invokePaletteItem(item: PaletteItem): void {
    const sourceId = item.sourceId ?? item.id;
    const sourceItem = this.#basePaletteItems().find((candidate) => candidate.id === sourceId) ?? item;
    this.#recordPaletteHistory(sourceItem);
    sourceItem.invoke();
    this.perform("palette.close");
  }

  #basePaletteItems(): PaletteItem[] {
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

    const repoItems = this.repositories.map((repository) => ({
      id: `repo:${repository.id}`,
      title: repository.displayName,
      subtitle: repository.path,
      section: "Repos" as const,
      invoke: () => {
        this.openSettingsSection("repositories");
      },
    }));

    const settingsItems = settingsSections.map((section) => ({
      id: `settings:${section.id}`,
      title: section.title,
      subtitle: section.subtitle,
      section: "Settings" as const,
      invoke: () => {
        this.openSettingsSection(section.id);
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
      ...settingsItems,
      ...repoItems,
      ...actionItems,
      ...tabItems,
      ...worktreeItems,
    ];
  }

  setView(view: AppView): void {
    this.view = view;
    void set(uiViewKey, view);
    this.syncRenderedPanes();
  }

  openSettingsSection(sectionId: (typeof settingsSections)[number]["id"]): void {
    this.setView("settings");
    if (typeof document === "undefined") {
      return;
    }
    requestAnimationFrame(() => {
      document.getElementById(`settings-${sectionId}`)?.scrollIntoView({ block: "start", behavior: "smooth" });
    });
  }

  selectWorktree(worktreeId: string): void {
    this.selectedWorktreeId = worktreeId;
    const firstPane = Array.from(this.panes.values()).find((pane) => pane.worktreeId === worktreeId);
    this.selectedPaneId = firstPane?.id ?? null;
    void set(selectedWorktreeKey, worktreeId);
    this.syncRenderedPanes();
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
    this.syncRenderedPanes();
  }

  reorderWorktree(repoId: string, draggedId: string, targetId: string): void {
    const worktrees = this.orderedWorktrees(repoId);
    const reordered = reorderIds(
      worktrees.map((worktree) => worktree.id),
      draggedId,
      targetId,
    );
    this.worktreeOrderByRepo = { ...this.worktreeOrderByRepo, [repoId]: reordered };
    persistJSONValue(worktreeOrderKey, this.worktreeOrderByRepo);
  }

  reorderPane(worktreeId: string, draggedId: string, targetId: string): void {
    const panes = this.orderedPanes(worktreeId);
    const reordered = reorderIds(
      panes.map((pane) => pane.id),
      draggedId,
      targetId,
    );
    this.paneOrderByWorktree = { ...this.paneOrderByWorktree, [worktreeId]: reordered };
    persistJSONValue(paneOrderKey, this.paneOrderByWorktree);
  }

  #replacePaneInOrder(worktreeId: string, previousPaneId: string, nextPaneId: string): void {
    const order = this.paneOrderByWorktree[worktreeId];
    if (!order?.includes(previousPaneId)) {
      return;
    }
    const replaced = order.map((paneId) => (paneId === previousPaneId ? nextPaneId : paneId));
    this.paneOrderByWorktree = { ...this.paneOrderByWorktree, [worktreeId]: replaced };
    persistJSONValue(paneOrderKey, this.paneOrderByWorktree);
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

  async login(): Promise<void> {
    const token = this.loginToken.trim();
    if (!token) {
      this.loginError = "Token is required.";
      return;
    }
    this.loginBusy = true;
    this.loginError = null;
    try {
      const response = await fetch(httpURLForWebSocket(this.daemonURL, "/auth/login"), {
        method: "POST",
        credentials: "include",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ token }),
      });
      if (!response.ok) {
        throw new Error(response.status === 401 ? "Invalid token." : `Login failed (${response.status}).`);
      }
      sessionStorage.removeItem(sessionTokenKey);
      this.loginToken = "";
      this.#connectDaemon("");
    } catch (error) {
      this.loginError = error instanceof Error ? error.message : String(error);
    } finally {
      this.loginBusy = false;
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
    if (!this.selectedPaneId) {
      return;
    }
    this.sendInputToPane(this.selectedPaneId, text);
  }

  sendInputToPane(paneId: string, text: string): void {
    const pane = this.panes.get(paneId);
    if (!pane) {
      return;
    }
    if (this.ws.sendBinary(pane.channelId, textEncoder.encode(text))) {
      this.#inputStartedByChannel.set(pane.channelId, performance.now());
    }
  }

  sendInputToVisiblePanes(text: string): void {
    for (const pane of this.visiblePanes) {
      this.sendInputToPane(pane.id, text);
    }
  }

  resizePane(paneId: string, cols: number, rows: number): void {
    const pane = this.panes.get(paneId);
    if (!pane || cols < 1 || rows < 1) {
      return;
    }
    const previous = this.#paneSizeById.get(paneId);
    if (previous?.cols === cols && previous.rows === rows) {
      return;
    }
    this.#paneSizeById.set(paneId, { cols, rows });
    this.ws.send({
      v: 1,
      type: "pane.resize",
      id: makeMessageId(),
      paneId,
      cols,
      rows,
    });
  }

  syncRenderedPanes(): void {
    const visiblePanes = this.visiblePanes;
    const visibleIds = new Set(visiblePanes.map((pane) => pane.id));
    this.#syncRendererPool(visiblePanes, visibleIds);
    for (const paneId of this.#renderedPaneIds) {
      if (!visibleIds.has(paneId)) {
        this.#renderedPaneIds.delete(paneId);
        this.ws.send({ v: 1, type: "pane.detach", id: makeMessageId(), paneId });
      }
    }
    for (const paneId of visibleIds) {
      if (!this.#renderedPaneIds.has(paneId)) {
        this.#renderedPaneIds.add(paneId);
        void this.ws
          .request({ v: 1, type: "pane.attach", id: makeMessageId(), paneId })
          .then((response) => {
            if (response.type === "pane.replay") {
              this.#applyPaneReplay(response.paneId, response.bytes);
            }
          })
          .catch((error) => {
            if (error instanceof ProtocolError && error.code === "PANE_GONE") {
              void this.#recreateGonePane(paneId);
              return;
            }
            this.errorMessage = error instanceof Error ? error.message : String(error);
          });
      }
    }
  }

  #syncRendererPool(visiblePanes: Pane[], visibleIds: Set<string>): void {
    this.rendererPool.releaseMissing(visibleIds);
    const selectedPane = this.selectedPaneId ? visiblePanes.find((pane) => pane.id === this.selectedPaneId) : undefined;
    const acquisitionOrder = selectedPane
      ? [...visiblePanes.filter((pane) => pane.id !== selectedPane.id), selectedPane]
      : visiblePanes;
    for (const pane of acquisitionOrder) {
      this.rendererPool.acquire(pane.id);
    }
    this.renderablePaneIds = new Set(this.rendererPool.activeIds);
  }

  async #recreateGonePane(paneId: string): Promise<void> {
    const stalePane = this.panes.get(paneId);
    if (!stalePane) {
      return;
    }
    this.errorMessage = null;
    this.#renderedPaneIds.delete(paneId);
    try {
      const response = await this.ws.request({
        v: 1,
        type: "pane.create",
        id: makeMessageId(),
        worktreeId: stalePane.worktreeId,
        cols: this.#paneSizeById.get(paneId)?.cols ?? 120,
        rows: this.#paneSizeById.get(paneId)?.rows ?? 32,
      });
      if (response.type === "pane.created") {
        this.#replacePaneInOrder(stalePane.worktreeId, paneId, response.paneId);
        this.#paneSizeById.delete(paneId);
      }
      this.#removePane(paneId);
      this.syncRenderedPanes();
    } catch (error) {
      this.errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  cycleWorktree(direction: 1 | -1): void {
    const worktrees = this.repositories.flatMap((repository) => this.orderedWorktrees(repository.id));
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
    const panes = this.selectedWorktreeId ? this.orderedPanes(this.selectedWorktreeId) : [];
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
    const [view, selectedWorktreeId, worktreeOrder, paneOrder, appearance, paletteHistory] = await Promise.all([
      get<AppView>(uiViewKey),
      get<string>(selectedWorktreeKey),
      get<Record<string, string[]>>(worktreeOrderKey),
      get<Record<string, string[]>>(paneOrderKey),
      get<AppSettings["appearance"]>(appearanceSettingsKey),
      get<PaletteHistoryEntry[]>(paletteHistoryKey),
    ]);
    if (view === "shelf" || view === "canvas" || view === "settings" || view === "diff") {
      this.view = view;
    }
    if (appearance) {
      this.settings = { ...this.settings, appearance: { ...this.settings.appearance, ...appearance } };
      this.#applyAppearanceSettings();
    }
    if (isStringArrayRecord(worktreeOrder)) {
      this.worktreeOrderByRepo = worktreeOrder;
    }
    if (isStringArrayRecord(paneOrder)) {
      this.paneOrderByWorktree = paneOrder;
    }
    if (Array.isArray(paletteHistory)) {
      this.paletteHistory = paletteHistory.filter(isPaletteHistoryEntry).slice(0, 10);
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
    this.daemonURL = new URL(url.searchParams.get("daemon") ?? defaultDaemonURL).toString();
    this.#connectDaemon(token);
    this.ws.onStatus((state) => {
      if (state === "open") {
        this.#prepareResumeAttach();
        void this.#bootstrapOnce(this.#authToken);
      }
    });
  }

  #connectDaemon(token: string): void {
    this.#authToken = token;
    const daemonURL = new URL(this.daemonURL);
    daemonURL.searchParams.delete("token");

    this.ws.connect(daemonURL.toString());
  }

  #bootstrapOnce(token: string): Promise<void> {
    this.#bootstrapPromise ??= this.#bootstrap(token).finally(() => {
      this.#bootstrapPromise = null;
    });
    return this.#bootstrapPromise;
  }

  #prepareResumeAttach(): void {
    if (!this.sessionId && this.#renderedPaneIds.size === 0) {
      return;
    }
    this.#paneIdsToResume = new Set(this.#renderedPaneIds);
    this.#renderedPaneIds.clear();
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
      await this.#resumeRenderedPanes();
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
      this.syncRenderedPanes();
    } catch (error) {
      this.errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  async #resumeRenderedPanes(): Promise<void> {
    const paneIds = Array.from(this.#paneIdsToResume);
    this.#paneIdsToResume.clear();
    for (const paneId of paneIds) {
      try {
        const response = await this.ws.request({ v: 1, type: "pane.attach", id: makeMessageId(), paneId });
        if (response.type === "pane.replay") {
          this.#renderedPaneIds.add(paneId);
          this.#applyPaneReplay(response.paneId, response.bytes);
        }
      } catch (error) {
        if (error instanceof ProtocolError && error.code === "PANE_GONE") {
          await this.#recreateGonePane(paneId);
          continue;
        }
        this.errorMessage = error instanceof Error ? error.message : String(error);
      }
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
      case "worktree.archiveProgress":
        this.errorMessage = null;
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
        this.syncRenderedPanes();
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
          this.syncRenderedPanes();
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
      case "pane.detached":
      case "pong":
        break;
    }
  }

  #handlePaneOutput(channelId: number, payload: Uint8Array): void {
    const pane = Array.from(this.panes.values()).find((candidate) => candidate.channelId === channelId);
    if (!pane) {
      return;
    }
    const inputStartedAt = this.#inputStartedByChannel.get(channelId);
    if (inputStartedAt !== undefined) {
      this.#inputStartedByChannel.delete(channelId);
      this.#recordInputLatency(performance.now() - inputStartedAt);
    }
    const decoder = this.#decoderByChannel.get(channelId) ?? new TextDecoder();
    this.#decoderByChannel.set(channelId, decoder);
    const text = decoder.decode(payload, { stream: true });
    const snapshot = appendTerminalOutput(pane.output, text);
    pane.output = snapshot.text;
    pane.lastOutputLine = snapshot.lastOutputLine || pane.lastOutputLine;
    pane.updatedAt = Date.now();
    pane.unread = pane.id !== this.selectedPaneId;
    const detectedStatus = inferAgentTaskStatus(pane.output);
    if (detectedStatus && detectedStatus !== pane.taskStatus) {
      void this.updatePaneStatus(pane.id, detectedStatus);
    }
  }

  #applyPaneReplay(paneId: string, base64: string): void {
    const pane = this.panes.get(paneId);
    if (!pane) {
      return;
    }
    const binary = atob(base64);
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    const snapshot = terminalOutputSnapshot(new TextDecoder().decode(bytes));
    pane.output = snapshot.text;
    pane.lastOutputLine = snapshot.lastOutputLine || pane.lastOutputLine;
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
    this.#pruneWorktreeOrder();
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
    this.#pruneWorktreeOrder();
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
    this.#prunePaneOrder();
    this.#ensureSelection();
  }

  #upsertPane(descriptor: PaneDescriptor): void {
    const next = new Map(this.panes);
    next.set(descriptor.id, new Pane(descriptor));
    this.panes = next;
    this.#prunePaneOrder();
  }

  #removePane(paneId: string): void {
    const pane = this.panes.get(paneId);
    const next = new Map(this.panes);
    next.delete(paneId);
    this.panes = next;
    this.#renderedPaneIds.delete(paneId);
    this.#paneIdsToResume.delete(paneId);
    this.#paneSizeById.delete(paneId);
    if (pane) {
      this.#decoderByChannel.delete(pane.channelId);
    }
    this.#prunePaneOrder();
    this.#ensureSelection();
  }

  #ensureSelection(): void {
    const orderedWorktrees = this.repositories.flatMap((repository) => this.orderedWorktrees(repository.id));
    if (!this.selectedWorktreeId || !orderedWorktrees.some((worktree) => worktree.id === this.selectedWorktreeId)) {
      this.selectedWorktreeId = orderedWorktrees[0]?.id ?? null;
    }
    if (!this.selectedPaneId || !this.panes.has(this.selectedPaneId)) {
      this.selectedPaneId = this.selectedWorktreeId
        ? (this.orderedPanes(this.selectedWorktreeId)[0]?.id ?? null)
        : null;
    }
  }

  #pruneWorktreeOrder(): void {
    const next: Record<string, string[]> = {};
    for (const [repoId, order] of Object.entries(this.worktreeOrderByRepo)) {
      const worktreeIds = new Set((this.worktreesByRepo.get(repoId) ?? []).map((worktree) => worktree.id));
      next[repoId] = order.filter((worktreeId) => worktreeIds.has(worktreeId));
    }
    this.worktreeOrderByRepo = next;
    persistJSONValue(worktreeOrderKey, this.worktreeOrderByRepo);
  }

  #prunePaneOrder(): void {
    const next: Record<string, string[]> = {};
    for (const [worktreeId, order] of Object.entries(this.paneOrderByWorktree)) {
      const paneIds = new Set(this.orderedPanes(worktreeId).map((pane) => pane.id));
      next[worktreeId] = order.filter((paneId) => paneIds.has(paneId));
    }
    this.paneOrderByWorktree = next;
    persistJSONValue(paneOrderKey, this.paneOrderByWorktree);
  }

  #mergeSettings(snapshot: Record<string, unknown>): void {
    this.settings = {
      appearance: sanitizeAppearance(snapshot.appearance, this.settings.appearance),
      shortcuts: sanitizeShortcuts(snapshot.shortcuts, this.settings.shortcuts),
      advanced: sanitizeAdvanced(snapshot.advanced, this.settings.advanced),
    };
    persistJSONValue(appearanceSettingsKey, this.settings.appearance);
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

  #recordPaletteHistory(item: PaletteItem): void {
    if (item.section === "Recent") {
      return;
    }
    const entry: PaletteHistoryEntry = {
      id: item.id,
      title: item.title,
      subtitle: item.subtitle,
      section: item.section,
    };
    this.paletteHistory = [entry, ...this.paletteHistory.filter((candidate) => candidate.id !== entry.id)].slice(0, 10);
    persistJSONValue(paletteHistoryKey, this.paletteHistory);
  }

  #startMetricLoop(): void {
    this.#metricTimer ??= setInterval(() => {
      if (this.connection !== "open") {
        return;
      }
      void this.#sampleWsRtt();
    }, 2_000);
  }

  async #sampleWsRtt(): Promise<void> {
    const startedAt = performance.now();
    try {
      const response = await this.ws.request({ v: 1, type: "ping", id: makeMessageId() }, 2_000);
      if (response.type === "pong") {
        this.#recordWsRtt(performance.now() - startedAt);
      }
    } catch {
      this.metrics = { ...this.metrics, lastWsRtt: null };
    }
  }

  #recordInputLatency(value: number): void {
    this.metrics = {
      ...this.metrics,
      inputLatencySamples: appendSample(this.metrics.inputLatencySamples, value),
    };
  }

  #recordWsRtt(value: number): void {
    this.metrics = {
      ...this.metrics,
      wsRttSamples: appendSample(this.metrics.wsRttSamples, value),
      lastWsRtt: value,
    };
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

function httpURLForWebSocket(wsURL: string, pathname: string): string {
  const url = new URL(wsURL);
  url.protocol = url.protocol === "wss:" ? "https:" : "http:";
  url.pathname = pathname;
  url.search = "";
  return url.toString();
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

function isPaletteHistoryEntry(value: unknown): value is PaletteHistoryEntry {
  if (!isRecord(value)) {
    return false;
  }
  return (
    typeof value.id === "string" &&
    typeof value.title === "string" &&
    typeof value.subtitle === "string" &&
    (value.section === "Tabs" ||
      value.section === "Worktrees" ||
      value.section === "Repos" ||
      value.section === "Actions" ||
      value.section === "Settings")
  );
}

function isStringArrayRecord(value: unknown): value is Record<string, string[]> {
  if (!isRecord(value)) {
    return false;
  }
  return Object.values(value).every(
    (entry) => Array.isArray(entry) && entry.every((candidate) => typeof candidate === "string"),
  );
}

function appendSample(samples: number[], value: number): number[] {
  return [...samples, value].slice(-maxMetricSamples);
}

function persistJSONValue(key: string, value: unknown): void {
  void set(key, JSON.parse(JSON.stringify(value))).catch(() => {});
}

function orderByIds<T>(items: T[], order: string[] | undefined, getId: (item: T) => string): T[] {
  if (!order || order.length === 0) {
    return items;
  }
  const indexById = new Map(order.map((id, index) => [id, index]));
  return [...items].sort((a, b) => {
    const aIndex = indexById.get(getId(a)) ?? Number.MAX_SAFE_INTEGER;
    const bIndex = indexById.get(getId(b)) ?? Number.MAX_SAFE_INTEGER;
    return aIndex - bIndex;
  });
}

function reorderIds(ids: string[], draggedId: string, targetId: string): string[] {
  if (draggedId === targetId) {
    return ids;
  }
  const withoutDragged = ids.filter((id) => id !== draggedId);
  const targetIndex = withoutDragged.indexOf(targetId);
  if (targetIndex === -1 || !ids.includes(draggedId)) {
    return ids;
  }
  return [...withoutDragged.slice(0, targetIndex), draggedId, ...withoutDragged.slice(targetIndex)];
}
