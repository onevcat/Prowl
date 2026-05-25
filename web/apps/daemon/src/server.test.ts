import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { makeMessageId, protocolVersion } from "@prowl/protocol";
import { handleControl } from "./server";
import { InMemoryState } from "./state/InMemoryState";

describe("daemon scaffold", () => {
  test("exports protocol version", () => {
    expect(protocolVersion).toBe(1);
  });

  test("validates repository paths before adding them", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-server-test-"));
    const state = new InMemoryState(root, { statePath: ":memory:", spawnProcesses: false });
    const config = {
      port: 0,
      bind: "127.0.0.1",
      token: "test-token",
      allowedOrigins: ["http://127.0.0.1:5173"],
      requireTLS: false,
    };

    const missing = handleControl(
      {
        v: 1,
        type: "repo.add",
        id: makeMessageId(),
        path: join(root, "missing"),
      },
      state,
      config,
    );
    const duplicate = handleControl(
      {
        v: 1,
        type: "repo.add",
        id: makeMessageId(),
        path: root,
      },
      state,
      config,
    );

    expect(missing[0]?.type).toBe("error");
    expect(duplicate[0]?.type).toBe("error");
  });

  test("creates and archives git worktrees", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-git-test-"));
    const repoPath = join(root, "repo");
    mkdirSync(repoPath);
    runGit(repoPath, "init");
    writeFileSync(join(repoPath, "README.md"), "test\n");
    runGit(repoPath, "add", "README.md");
    runGit(repoPath, "-c", "user.name=Prowl Test", "-c", "user.email=prowl@example.com", "commit", "-m", "initial");

    const state = new InMemoryState(repoPath, { statePath: ":memory:", spawnProcesses: false });
    const config = {
      port: 0,
      bind: "127.0.0.1",
      token: "test-token",
      allowedOrigins: ["http://127.0.0.1:5173"],
      requireTLS: false,
    };

    const created = handleControl(
      {
        v: 1,
        type: "worktree.create",
        id: makeMessageId(),
        repoId: "repo-default",
        branch: "feature/web",
      },
      state,
      config,
    );
    expect(created[0]?.type).toBe("worktree.updated");
    if (created[0]?.type !== "worktree.updated") {
      throw new Error("Expected worktree.updated");
    }
    const createdWorktree = created[0].worktree;
    expect(createdWorktree.branch).toBe("feature/web");
    expect(state.worktreesByRepo.get("repo-default")?.some((worktree) => worktree.id === createdWorktree.id)).toBe(
      true,
    );

    const archived = handleControl(
      {
        v: 1,
        type: "worktree.archive",
        id: makeMessageId(),
        worktreeId: createdWorktree.id,
      },
      state,
      config,
    );
    expect(archived[0]?.type).toBe("worktree.updated");
    if (archived[0]?.type !== "worktree.updated") {
      throw new Error("Expected archived worktree.updated");
    }
    expect(archived[0].worktree.status).toBe("archived");
    expect(state.worktreesByRepo.get("repo-default")?.some((worktree) => worktree.id === createdWorktree.id)).toBe(
      false,
    );
  });

  test("creates and lists custom actions", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-action-test-"));
    const state = new InMemoryState(root, { statePath: ":memory:", spawnProcesses: false });
    const config = {
      port: 0,
      bind: "127.0.0.1",
      token: "test-token",
      allowedOrigins: ["http://127.0.0.1:5173"],
      requireTLS: false,
    };

    const updated = handleControl(
      {
        v: 1,
        type: "action.upsert",
        id: makeMessageId(),
        action: {
          repoId: null,
          name: "Echo",
          command: "echo hello",
          outputMode: "currentPane",
          ordering: 1,
        },
      },
      state,
      config,
    );
    expect(updated[0]?.type).toBe("action.updated");
    const listed = handleControl({ v: 1, type: "action.list", id: makeMessageId() }, state, config);

    expect(listed[0]?.type).toBe("action.listed");
    if (listed[0]?.type !== "action.listed") {
      throw new Error("Expected action.listed");
    }
    expect(listed[0].actions).toHaveLength(1);
    expect(listed[0].actions[0]?.command).toBe("echo hello");
  });

  test("reads git diff for a worktree", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-diff-test-"));
    const repoPath = join(root, "repo");
    mkdirSync(repoPath);
    runGit(repoPath, "init");
    writeFileSync(join(repoPath, "README.md"), "before\n");
    runGit(repoPath, "add", "README.md");
    runGit(repoPath, "-c", "user.name=Prowl Test", "-c", "user.email=prowl@example.com", "commit", "-m", "initial");
    writeFileSync(join(repoPath, "README.md"), "after\n");

    const state = new InMemoryState(repoPath, { statePath: ":memory:", spawnProcesses: false });
    const config = {
      port: 0,
      bind: "127.0.0.1",
      token: "test-token",
      allowedOrigins: ["http://127.0.0.1:5173"],
      requireTLS: false,
    };

    const diff = handleControl(
      {
        v: 1,
        type: "worktree.diff",
        id: makeMessageId(),
        worktreeId: "worktree-default",
      },
      state,
      config,
    );

    expect(diff[0]?.type).toBe("worktree.diffed");
    if (diff[0]?.type !== "worktree.diffed") {
      throw new Error("Expected worktree.diffed");
    }
    expect(diff[0].diff.text).toContain("-before");
    expect(diff[0].diff.text).toContain("+after");
  });

  test("updates pane status and emits done notification", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-status-test-"));
    const state = new InMemoryState(root, { statePath: ":memory:", spawnProcesses: false });
    const config = {
      port: 0,
      bind: "127.0.0.1",
      token: "test-token",
      allowedOrigins: ["http://127.0.0.1:5173"],
      requireTLS: false,
    };
    const [pane] = state.listPanes();
    if (!pane) {
      throw new Error("Expected seeded pane");
    }

    const running = handleControl(
      {
        v: 1,
        type: "pane.status",
        id: makeMessageId(),
        paneId: pane.id,
        taskStatus: "running",
      },
      state,
      config,
    );
    const done = handleControl(
      {
        v: 1,
        type: "pane.status",
        id: makeMessageId(),
        paneId: pane.id,
        taskStatus: "done",
      },
      state,
      config,
    );

    expect(running[0]?.type).toBe("pane.listed");
    expect(state.listPanes()[0]?.taskStatus).toBe("done");
    expect(done[0]?.type).toBe("notification");
  });
});

function runGit(cwd: string, ...args: string[]): void {
  const result = Bun.spawnSync(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  if (result.exitCode !== 0) {
    throw new Error(new TextDecoder().decode(result.stderr) || new TextDecoder().decode(result.stdout));
  }
}
