import { describe, expect, test } from "bun:test";
import { InMemoryState } from "./InMemoryState";

describe("InMemoryState", () => {
  test("seeds a repository, worktree, and pane", () => {
    const state = testState();
    const [repository] = state.repositories;
    expect(repository).toBeDefined();

    expect(repository?.displayName).toBe("prowl");
    expect(repository ? state.worktreesByRepo.get(repository.id)?.length : 0).toBe(1);
    expect(state.listPanes()).toHaveLength(1);
  });

  test("creates and closes panes", () => {
    const state = testState();
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
    const state = testState();

    expect(state.replayForPane("missing")).toBeNull();
  });

  test("persists repositories and settings in sqlite", () => {
    const statePath = `/tmp/prowl-test-${crypto.randomUUID()}.sqlite`;
    const first = new InMemoryState("/tmp/prowl", { spawnProcesses: false, statePath });
    const { repository } = first.addRepository("/tmp/other-repo");
    first.updateSettings({ theme: "dark" });

    const second = new InMemoryState("/tmp/prowl", { spawnProcesses: false, statePath });

    expect(second.repositories.some((candidate) => candidate.id === repository.id)).toBe(true);
    expect(second.settingsSnapshot(["theme"]).theme).toBe("dark");
  });

  test("persists custom actions in sqlite", () => {
    const statePath = `/tmp/prowl-actions-test-${crypto.randomUUID()}.sqlite`;
    const first = new InMemoryState("/tmp/prowl", { spawnProcesses: false, statePath });
    const action = first.upsertCustomAction({
      repoId: null,
      name: "Status",
      command: "git status --short",
      outputMode: "currentPane",
      ordering: 1,
    });

    const second = new InMemoryState("/tmp/prowl", { spawnProcesses: false, statePath });

    expect(second.listCustomActions().some((candidate) => candidate.id === action.id)).toBe(true);
    expect(second.customAction(action.id)?.command).toBe("git status --short");
  });
});

function testState(): InMemoryState {
  return new InMemoryState("/tmp/prowl", { spawnProcesses: false, statePath: ":memory:" });
}
