import { describe, expect, test } from "vitest";
import { AppState } from "./AppState.svelte";
import { Pane } from "./Pane.svelte";
import type { Repository, Worktree } from "./types";

const globalWithRunes = globalThis as typeof globalThis & {
  $state?: <T>(value: T) => T;
};

globalWithRunes.$state = ((value: unknown) => value) as typeof globalWithRunes.$state;

describe("AppState ordering", () => {
  test("orders worktrees and panes according to drag reorder state", () => {
    const state = appStateFixture();

    state.reorderWorktree("repo-1", "worktree-2", "worktree-1");
    state.reorderPane("worktree-1", "pane-2", "pane-1");

    expect(state.orderedWorktrees("repo-1").map((worktree) => worktree.id)).toEqual(["worktree-2", "worktree-1"]);
    expect(state.orderedPanes("worktree-1").map((pane) => pane.id)).toEqual(["pane-2", "pane-1"]);
  });

  test("selecting a worktree selects the first pane in the user-defined tab order", () => {
    const state = appStateFixture();
    state.reorderPane("worktree-1", "pane-2", "pane-1");

    state.selectWorktree("worktree-1");

    expect(state.selectedPaneId).toBe("pane-2");
  });
});

function appStateFixture(): AppState {
  const state = new AppState();
  const repository: Repository = {
    id: "repo-1",
    path: "/repo",
    displayName: "Repo",
    color: "#0a84ff",
  };
  const worktrees: Worktree[] = [worktree("worktree-1", "one"), worktree("worktree-2", "two")];

  state.repositories = [repository];
  state.worktreesByRepo = new Map([["repo-1", worktrees]]);
  state.panes = new Map([
    ["pane-1", pane("pane-1", 1)],
    ["pane-2", pane("pane-2", 2)],
  ]);
  state.selectedWorktreeId = "worktree-1";
  state.selectedPaneId = "pane-1";

  return state;
}

function worktree(id: string, name: string): Worktree {
  return {
    id,
    repoId: "repo-1",
    path: `/repo/${name}`,
    name,
    branch: "main",
    status: "clean",
    taskStatus: "idle",
    unreadCount: 0,
  };
}

function pane(id: string, channelId: number): Pane {
  return new Pane({
    id,
    channelId,
    worktreeId: "worktree-1",
    title: id,
    taskStatus: "idle",
    unread: false,
    lastOutputLine: "",
    updatedAt: 0,
  });
}
