import type { PaneDescriptor, Worktree } from "@prowl/protocol";

const reset = "\x1b[0m";

const statusColors: Record<string, string> = {
  idle: "#8e8e93",
  running: "#0a84ff",
  done: "#34c759",
  failed: "#ff3b30",
  clean: "#34c759",
  dirty: "#ff9500",
  archived: "#8e8e93",
};

export function color(text: string, value: string): string {
  const prefix = Bun.color(value, "ansi-256") ?? "";
  return prefix ? `${prefix}${text}${reset}` : text;
}

export function colorStatus(status: string | undefined): string {
  if (!status) {
    return color("unknown", "#8e8e93");
  }
  return color(status, statusColors[status] ?? "#8e8e93");
}

export function formatPane(pane: PaneDescriptor): string {
  return `${pane.id}\t${pane.worktreeId}\t${colorStatus(pane.taskStatus)}\t${pane.title}`;
}

export function formatWorktree(worktree: Worktree): string {
  return `${worktree.id}\t${worktree.repoId}\t${worktree.branch}\t${colorStatus(worktree.status)}\t${worktree.path}`;
}
