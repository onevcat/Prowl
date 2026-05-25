import type { PaneDescriptor, Repository, TaskStatus, Worktree, WorktreeDiff } from "@prowl/protocol";

export type { PaneDescriptor, Repository, TaskStatus, Worktree, WorktreeDiff };

export type AppView = "shelf" | "canvas" | "settings" | "diff";

export type ConnectionState = "connecting" | "open" | "closed";

export type PaletteItem = {
  id: string;
  sourceId?: string;
  title: string;
  subtitle: string;
  section: "Tabs" | "Worktrees" | "Repos" | "Actions" | "Settings" | "Recent";
  invoke: () => void;
};

export type AppearanceSettings = {
  theme: "system" | "light" | "dark";
  terminalDensity: "compact" | "comfortable";
  showUnreadBadges: boolean;
};

export type ShortcutSettings = Partial<Record<ActionId, string>>;

export type AdvancedSettings = {
  performanceHUD: boolean;
  confirmDestructiveActions: boolean;
  replayBufferKiB: number;
};

export type PerformanceMetrics = {
  inputLatencySamples: number[];
  wsRttSamples: number[];
  wsReconnectSamples: number[];
  worktreeSwitchSamples: number[];
  paletteOpenSamples: number[];
  lastWsRtt: number | null;
};

export type PaletteHistoryEntry = {
  id: string;
  title: string;
  subtitle: string;
  section: Exclude<PaletteItem["section"], "Recent">;
};

export type AppSettings = {
  appearance: AppearanceSettings;
  shortcuts: ShortcutSettings;
  advanced: AdvancedSettings;
};

export type ActionId =
  | "view.shelf"
  | "view.canvas"
  | "view.settings"
  | "view.diff"
  | "palette.open"
  | "palette.close"
  | "performance.toggle"
  | "pane.new"
  | "pane.close"
  | "worktree.next"
  | "worktree.previous"
  | "tab.next"
  | "tab.previous";
