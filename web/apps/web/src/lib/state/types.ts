import type { PaneDescriptor, Repository, TaskStatus, Worktree } from "@prowl/protocol";

export type { PaneDescriptor, Repository, TaskStatus, Worktree };

export type AppView = "shelf" | "canvas";

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
  | "palette.open"
  | "palette.close"
  | "pane.new"
  | "pane.close"
  | "worktree.next"
  | "worktree.previous"
  | "tab.next"
  | "tab.previous";
