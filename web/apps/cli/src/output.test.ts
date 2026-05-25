import { describe, expect, test } from "bun:test";
import type { PaneDescriptor, Worktree } from "@prowl/protocol";
import { colorStatus, formatPane, formatWorktree } from "./output";

describe("CLI human output", () => {
  test("colorizes task statuses with Bun ANSI colors", () => {
    expect(colorStatus("running")).toContain("\x1b[38;5;");
    expect(Bun.stripANSI(colorStatus("running"))).toBe("running");
  });

  test("keeps tabular pane output readable after stripping ANSI", () => {
    const pane: PaneDescriptor = {
      id: "pane-1",
      worktreeId: "worktree-1",
      channelId: 1,
      title: "Shell",
      taskStatus: "done",
      unread: false,
      lastOutputLine: "",
      updatedAt: 0,
    };

    expect(Bun.stripANSI(formatPane(pane))).toBe("pane-1\tworktree-1\tdone\tShell");
  });

  test("keeps tabular worktree output readable after stripping ANSI", () => {
    const worktree: Worktree = {
      id: "worktree-1",
      repoId: "repo-1",
      path: "/repo",
      name: "main",
      branch: "main",
      status: "clean",
      taskStatus: "idle",
      unreadCount: 0,
    };

    expect(Bun.stripANSI(formatWorktree(worktree))).toBe("worktree-1\trepo-1\tmain\tclean\t/repo");
  });
});
