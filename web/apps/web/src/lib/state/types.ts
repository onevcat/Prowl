import type { PaneDescriptor, Repository, TaskStatus, Worktree, WorktreeDiff } from "@prowl/protocol";

export type { PaneDescriptor, Repository, TaskStatus, Worktree, WorktreeDiff };

export type AppView = "shelf" | "canvas" | "settings" | "diff";

export type ConnectionState = "connecting" | "open" | "closed";

export type PaletteItem = {
  id: string;
  title: string;
  subtitle: string;
  section: "Tabs" | "Worktrees" | "Repos" | "Actions" | "Settings";
  invoke: () => void;
};

export type ActionId =
  | "view.shelf"
  | "view.canvas"
  | "view.settings"
  | "palette.open"
  | "palette.close"
  | "pane.new"
  | "pane.close"
  | "worktree.next"
  | "worktree.previous"
  | "tab.next"
  | "tab.previous";
