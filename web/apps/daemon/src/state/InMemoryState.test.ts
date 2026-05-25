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

  test("uses requested pane dimensions when spawning PTYs", () => {
    const spawnOptions: Array<{ cols: number; rows: number }> = [];
    const state = new InMemoryState("/tmp/prowl", {
      statePath: ":memory:",
      spawnPaneProcess: (options) => {
        spawnOptions.push({ cols: options.cols, rows: options.rows });
        return {
          kill: () => {},
          exited: new Promise(() => {}),
          terminal: {
            close: () => {},
            resize: () => {},
            write: () => {},
          },
        };
      },
    });
    const repository = state.repositories[0];
    const [worktree] = repository ? (state.worktreesByRepo.get(repository.id) ?? []) : [];
    if (!worktree) {
      throw new Error("Expected seeded worktree");
    }

    state.createPane(worktree.id, "Sized", undefined, undefined, { cols: 101, rows: 43 });

    expect(spawnOptions.at(-1)).toEqual({ cols: 101, rows: 43 });
  });

  test("returns null replay for missing panes", () => {
    const state = testState();

    expect(state.replayForPane("missing")).toBeNull();
  });

  test("keeps pane replay within the default 64 KiB ring", () => {
    const { state, spawned } = stateWithCapturedPtyOutput();
    const [pane] = state.listPanes();
    if (!pane || !spawned[0]) {
      throw new Error("Expected seeded pane and PTY");
    }

    spawned[0].onData(repeatedBytes(70 * 1024, 65));

    const replay = state.replayForPane(pane.id);
    expect(replay?.byteLength).toBe(64 * 1024);
  });

  test("applies advanced replayBufferKiB to existing and future replay data", () => {
    const { state, spawned } = stateWithCapturedPtyOutput();
    const [pane] = state.listPanes();
    if (!pane || !spawned[0]) {
      throw new Error("Expected seeded pane and PTY");
    }

    spawned[0].onData(repeatedBytes(20 * 1024, 65));
    state.updateSettings({ advanced: { replayBufferKiB: 16 } });

    expect(state.replayForPane(pane.id)?.byteLength).toBe(16 * 1024);

    spawned[0].onData(repeatedBytes(8 * 1024, 66));

    const replay = state.replayForPane(pane.id);
    expect(replay?.byteLength).toBe(16 * 1024);
    expect(replay?.at(-1)).toBe(66);
  });

  test("loads persisted replayBufferKiB before appending pane output", () => {
    const statePath = `/tmp/prowl-replay-test-${crypto.randomUUID()}.sqlite`;
    const first = new InMemoryState("/tmp/prowl", { spawnProcesses: false, statePath });
    first.updateSettings({ advanced: { replayBufferKiB: 16 } });

    const spawned: Array<{ onData: (data: Uint8Array) => void }> = [];
    const second = new InMemoryState("/tmp/prowl", {
      statePath,
      spawnPaneProcess: (options) => {
        spawned.push({ onData: options.onData });
        return {
          kill: () => {},
          exited: new Promise(() => {}),
          terminal: {
            close: () => {},
            resize: () => {},
            write: () => {},
          },
        };
      },
    });
    const [pane] = second.listPanes();
    if (!pane || !spawned[0]) {
      throw new Error("Expected persisted pane and PTY");
    }

    spawned[0].onData(repeatedBytes(20 * 1024, 65));

    expect(second.replayForPane(pane.id)?.byteLength).toBe(16 * 1024);
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

  test("emits pane exit callbacks when PTY processes end", async () => {
    let resolveExited: (event: { paneId: string; exitCode: number }) => void = () => {};
    let resolveProcessExit: (exitCode: number) => void = () => {};
    const processExited = new Promise<number>((resolve) => {
      resolveProcessExit = resolve;
    });
    const exited = new Promise<{ paneId: string; exitCode: number }>((resolve) => {
      resolveExited = resolve;
    });
    const state = new InMemoryState("/tmp/prowl", {
      statePath: ":memory:",
      spawnPaneProcess: () => ({
        kill: () => {},
        exited: processExited,
        terminal: {
          close: () => {},
          resize: () => {},
          write: () => {},
        },
      }),
      onPaneExit: (paneId, exitCode) => {
        resolveExited({ paneId, exitCode });
      },
    });
    for (const pane of state.listPanes()) {
      state.closePane(pane.id);
    }
    const repository = state.repositories[0];
    const [worktree] = repository ? (state.worktreesByRepo.get(repository.id) ?? []) : [];
    if (!worktree) {
      throw new Error("Expected seeded worktree");
    }
    const pane = state.createPane(worktree.id, "Exit", "exit 7");
    resolveProcessExit(7);

    const event = await Promise.race([
      exited,
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error("Timed out waiting for pane exit")), 2_000)),
    ]);

    expect(event).toEqual({ paneId: pane.id, exitCode: 7 });
    expect(state.listPanes().some((candidate) => candidate.id === pane.id)).toBe(false);
    expect(state.replayForPane(pane.id)).toBeNull();
    expect(state.paneForChannel(pane.channelId)).toBeNull();
  });
});

function testState(): InMemoryState {
  return new InMemoryState("/tmp/prowl", { spawnProcesses: false, statePath: ":memory:" });
}

function stateWithCapturedPtyOutput(): {
  state: InMemoryState;
  spawned: Array<{ onData: (data: Uint8Array) => void }>;
} {
  const spawned: Array<{ onData: (data: Uint8Array) => void }> = [];
  const state = new InMemoryState("/tmp/prowl", {
    statePath: ":memory:",
    spawnPaneProcess: (options) => {
      spawned.push({ onData: options.onData });
      return {
        kill: () => {},
        exited: new Promise(() => {}),
        terminal: {
          close: () => {},
          resize: () => {},
          write: () => {},
        },
      };
    },
  });
  return { state, spawned };
}

function repeatedBytes(length: number, byte: number): Uint8Array {
  return new Uint8Array(length).fill(byte);
}
