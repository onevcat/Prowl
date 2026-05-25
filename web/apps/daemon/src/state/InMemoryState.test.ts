import { describe, expect, test } from "bun:test";
import { InMemoryState } from "./InMemoryState";

describe("InMemoryState", () => {
  test("seeds a repository, worktree, and pane", () => {
    const state = new InMemoryState("/tmp/prowl", { spawnProcesses: false });
    const [repository] = state.repositories;
    expect(repository).toBeDefined();

    expect(repository?.displayName).toBe("prowl");
    expect(repository ? state.worktreesByRepo.get(repository.id)?.length : 0).toBe(1);
    expect(state.listPanes()).toHaveLength(1);
  });

  test("creates and closes panes", () => {
    const state = new InMemoryState("/tmp/prowl", { spawnProcesses: false });
    const repository = state.repositories[0];
    expect(repository).toBeDefined();
    const [worktree] = repository ? (state.worktreesByRepo.get(repository.id) ?? []) : [];
    expect(worktree).toBeDefined();
    if (!worktree) {
      throw new Error("Expected seeded worktree");
    }
    const pane = state.createPane(worktree.id);

    expect(state.listPanes().some((candidate) => candidate.id === pane.id)).toBe(true);
    expect(state.closePane(pane.id)).toBe(true);
    expect(state.listPanes().some((candidate) => candidate.id === pane.id)).toBe(false);
  });

  test("returns null replay for missing panes", () => {
    const state = new InMemoryState("/tmp/prowl", { spawnProcesses: false });

    expect(state.replayForPane("missing")).toBeNull();
  });
});
