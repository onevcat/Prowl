import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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

  test("closes panes that belong to a removed repository", () => {
    const state = testState();
    const { repository, worktree } = state.addRepository("/tmp/removed-repo");
    const pane = state.createPane(worktree.id);

    expect(state.listPanes().some((candidate) => candidate.id === pane.id)).toBe(true);

    expect(state.removeRepository(repository.id)).toBe(true);

    expect(state.repositories.some((candidate) => candidate.id === repository.id)).toBe(false);
    expect(state.worktreesByRepo.get(repository.id)).toBeUndefined();
    expect(state.listPanes().some((candidate) => candidate.id === pane.id)).toBe(false);
  });

  test("uses requested pane dimensions when spawning PTYs", () => {
    const spawnOptions: Array<{ cols: number; rows: number }> = [];
    const root = mkdtempSync(join(tmpdir(), "prowl-pane-size-test-"));
    const state = new InMemoryState(root, {
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

  test("spawns pane processes with a Bun Terminal PTY", async () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-pty-state-"));
    const outputByChannel = new Map<number, string>();
    const state = new InMemoryState(root, {
      statePath: ":memory:",
      onPaneData: (channelId, payload) => {
        outputByChannel.set(channelId, `${outputByChannel.get(channelId) ?? ""}${new TextDecoder().decode(payload)}`);
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

    const pane = state.createPane(worktree.id, "TTY", "if test -t 1; then printf prowl-tty-yes; fi");

    try {
      const output = await poll(
        () => outputByChannel.get(pane.channelId) ?? "",
        (value) => value.includes("prowl-tty-yes"),
      );

      expect(output).toContain("prowl-tty-yes");
    } finally {
      state.closePane(pane.id);
    }
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

  test("does not expose pane metadata through settings snapshots", () => {
    const state = new InMemoryState("/tmp/prowl", { spawnProcesses: false, statePath: ":memory:" });

    expect(state.settingsSnapshot().panes).toBeUndefined();
    expect(state.settingsSnapshot(["panes"]).panes).toBeUndefined();
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

  test("emits pane status callbacks when custom actions finish", async () => {
    let resolveStatus: (pane: ReturnType<InMemoryState["listPanes"]>[number]) => void = () => {};
    const statusUpdated = new Promise<ReturnType<InMemoryState["listPanes"]>[number]>((resolve) => {
      resolveStatus = resolve;
    });
    const root = mkdtempSync(join(tmpdir(), "prowl-action-status-test-"));
    const state = new InMemoryState(root, {
      statePath: ":memory:",
      spawnProcesses: false,
      onPaneStatus: (pane) => {
        resolveStatus(pane);
      },
    });
    const [pane] = state.listPanes();
    if (!pane) {
      throw new Error("Expected seeded pane");
    }
    const action = state.upsertCustomAction({
      repoId: null,
      name: "Finish",
      command: "printf custom-action-finished",
      outputMode: "currentPane",
      ordering: 1,
    });

    state.runCustomAction(pane.id, action.id);

    const updated = await Promise.race([
      statusUpdated,
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error("Timed out waiting for status")), 2_000)),
    ]);

    expect(updated.id).toBe(pane.id);
    expect(updated.taskStatus).toBe("done");
    expect(updated.lastOutputLine).toBe("custom-action-finished");
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

async function poll<T>(read: () => T, done: (value: T) => boolean): Promise<T> {
  const deadline = Date.now() + 2_000;
  while (Date.now() < deadline) {
    const value = read();
    if (done(value)) {
      return value;
    }
    await Bun.sleep(20);
  }
  throw new Error("Timed out waiting for condition");
}
