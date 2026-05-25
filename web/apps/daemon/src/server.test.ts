import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { makeMessageId, protocolVersion } from "@prowl/protocol";
import { allowControlMessage, authenticateUpgradeToken, handleControl, startServer, tokenFromRequest } from "./server";
import { InMemoryState } from "./state/InMemoryState";

describe("daemon scaffold", () => {
  test("exports protocol version", () => {
    expect(protocolVersion).toBe(1);
  });

  test("refuses to start remote mode without TLS material", () => {
    expect(() =>
      startServer(
        {
          port: 0,
          bind: "0.0.0.0",
          token: "test-token",
          allowedOrigins: ["https://example.com"],
          requireTLS: true,
        },
        { socketPath: false, statePath: ":memory:", spawnProcesses: false },
      ),
    ).toThrow("TLS is required");
  });

  test("refuses to start with an empty auth token", () => {
    expect(() =>
      startServer(
        {
          port: 0,
          bind: "127.0.0.1",
          token: "",
          allowedOrigins: ["http://127.0.0.1:5173"],
          requireTLS: false,
        },
        { socketPath: false, statePath: ":memory:", spawnProcesses: false },
      ),
    ).toThrow("auth token must not be empty");
  });

  test("issues an HttpOnly session cookie from the login endpoint", async () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-login-test-"));
    const server = startServer(
      {
        port: 0,
        bind: "127.0.0.1",
        token: "test-token",
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      },
      { socketPath: false, statePath: join(root, "state.sqlite"), spawnProcesses: false },
    );
    try {
      const response = await fetch(new URL("/auth/login", server.url), {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Origin: "http://127.0.0.1:5173",
        },
        body: JSON.stringify({ token: "test-token" }),
      });

      expect(response.status).toBe(200);
      expect(response.headers.get("Set-Cookie")).toContain("prowl_session=test-token; HttpOnly");
      expect(response.headers.get("Access-Control-Allow-Origin")).toBe("http://127.0.0.1:5173");
      expect(response.headers.get("Access-Control-Allow-Credentials")).toBe("true");
    } finally {
      server.stop();
    }
  });

  test("answers login CORS preflight for allowed origins", async () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-login-preflight-test-"));
    const server = startServer(
      {
        port: 0,
        bind: "127.0.0.1",
        token: "test-token",
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      },
      { socketPath: false, statePath: join(root, "state.sqlite"), spawnProcesses: false },
    );
    try {
      const response = await fetch(new URL("/auth/login", server.url), {
        method: "OPTIONS",
        headers: {
          Origin: "http://127.0.0.1:5173",
          "Access-Control-Request-Method": "POST",
          "Access-Control-Request-Headers": "Content-Type",
        },
      });

      expect(response.status).toBe(204);
      expect(response.headers.get("Access-Control-Allow-Origin")).toBe("http://127.0.0.1:5173");
      expect(response.headers.get("Access-Control-Allow-Methods")).toContain("POST");
    } finally {
      server.stop();
    }
  });

  test("allows hello on a connection already authenticated during upgrade", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-authenticated-hello-test-"));
    const state = new InMemoryState(root, { statePath: ":memory:", spawnProcesses: false });
    const config = {
      port: 0,
      bind: "127.0.0.1",
      token: "test-token",
      allowedOrigins: ["http://127.0.0.1:5173"],
      requireTLS: false,
    };

    const response = handleControl(
      {
        v: 1,
        type: "hello",
        id: makeMessageId(),
        token: "",
        clientVersion: "0.0.0",
        protocolVersion,
      },
      state,
      config,
      { authenticated: true },
    );

    expect(response[0]?.type).toBe("welcome");
  });

  test("allows websocket upgrade without a token for hello-first authentication", () => {
    const config = { token: "test-token" };

    expect(authenticateUpgradeToken(null, config)).toEqual({ allowed: true, authenticated: false });
    expect(authenticateUpgradeToken("test-token", config)).toEqual({ allowed: true, authenticated: true });
    expect(authenticateUpgradeToken("wrong-token", config)).toEqual({ allowed: false, authenticated: false });
  });

  test("reads websocket token from authorization bearer header", () => {
    const request = new Request("http://127.0.0.1/ws", {
      headers: {
        Authorization: "Bearer test-token",
      },
    });

    expect(tokenFromRequest(request, new URL(request.url))).toBe("test-token");
  });

  test("prefers explicit websocket query token over authorization and cookie tokens", () => {
    const request = new Request("http://127.0.0.1/ws?token=query-token", {
      headers: {
        Authorization: "Bearer header-token",
        Cookie: "prowl_session=cookie-token",
      },
    });

    expect(tokenFromRequest(request, new URL(request.url))).toBe("query-token");
  });

  test("ignores non-bearer authorization headers when reading websocket token", () => {
    const request = new Request("http://127.0.0.1/ws", {
      headers: {
        Authorization: "Basic test-token",
        Cookie: "prowl_session=cookie-token",
      },
    });

    expect(tokenFromRequest(request, new URL(request.url))).toBe("cookie-token");
  });

  test("accepts hello token on an unauthenticated connection", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-hello-first-test-"));
    const state = new InMemoryState(root, { statePath: ":memory:", spawnProcesses: false });
    const config = {
      port: 0,
      bind: "127.0.0.1",
      token: "test-token",
      allowedOrigins: ["http://127.0.0.1:5173"],
      requireTLS: false,
    };

    const accepted = handleControl(
      {
        v: 1,
        type: "hello",
        id: makeMessageId(),
        token: "test-token",
        clientVersion: "0.0.0",
        protocolVersion,
      },
      state,
      config,
      { authenticated: false },
    );
    const rejected = handleControl(
      {
        v: 1,
        type: "hello",
        id: makeMessageId(),
        token: "wrong-token",
        clientVersion: "0.0.0",
        protocolVersion,
      },
      state,
      config,
      { authenticated: false },
    );

    expect(accepted[0]?.type).toBe("welcome");
    expect(rejected[0]?.type).toBe("error");
  });

  test("rejects newer client protocol versions before accepting hello", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-protocol-mismatch-test-"));
    const state = new InMemoryState(root, { statePath: ":memory:", spawnProcesses: false });
    const config = {
      port: 0,
      bind: "127.0.0.1",
      token: "test-token",
      allowedOrigins: ["http://127.0.0.1:5173"],
      requireTLS: false,
    };

    const response = handleControl(
      {
        v: 1,
        type: "hello",
        id: makeMessageId(),
        token: "wrong-token",
        clientVersion: "0.0.0",
        protocolVersion: protocolVersion + 1,
      },
      state,
      config,
      { authenticated: false },
    );

    expect(response[0]?.type).toBe("error");
    if (response[0]?.type === "error") {
      expect(response[0].code).toBe("PROTOCOL_MISMATCH");
    }
  });

  test("rate-limits control messages per session", () => {
    const session = {
      authenticated: true,
      sessionId: crypto.randomUUID(),
      ownedPaneIds: new Set<string>(),
      controlWindowStartedAt: 1_000,
      controlMessagesInWindow: 0,
    };

    for (let count = 0; count < 100; count += 1) {
      expect(allowControlMessage(session, 1_500)).toBe(true);
    }
    expect(allowControlMessage(session, 1_500)).toBe(false);
    expect(allowControlMessage(session, 2_001)).toBe(true);
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

  test("rejects control messages for missing target objects", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-target-validation-test-"));
    const state = new InMemoryState(root, { statePath: ":memory:", spawnProcesses: false });
    const config = {
      port: 0,
      bind: "127.0.0.1",
      token: "test-token",
      allowedOrigins: ["http://127.0.0.1:5173"],
      requireTLS: false,
    };

    const worktrees = handleControl(
      { v: 1, type: "worktree.list", id: makeMessageId(), repoId: "missing" },
      state,
      config,
    );
    const pane = handleControl(
      {
        v: 1,
        type: "pane.create",
        id: makeMessageId(),
        worktreeId: "missing",
        cols: 120,
        rows: 32,
      },
      state,
      config,
    );
    const resized = handleControl(
      { v: 1, type: "pane.resize", id: makeMessageId(), paneId: "missing", cols: 120, rows: 32 },
      state,
      config,
    );
    const closed = handleControl({ v: 1, type: "pane.close", id: makeMessageId(), paneId: "missing" }, state, config);
    const removed = handleControl({ v: 1, type: "repo.remove", id: makeMessageId(), repoId: "missing" }, state, config);

    expect(worktrees[0]?.type).toBe("error");
    expect(pane[0]?.type).toBe("error");
    expect(resized[0]?.type).toBe("error");
    expect(closed[0]?.type).toBe("error");
    expect(removed[0]?.type).toBe("error");
  });

  test("rejects pane operations outside the session ownership set", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-pane-ownership-test-"));
    const state = new InMemoryState(root, { statePath: ":memory:", spawnProcesses: false });
    const config = {
      port: 0,
      bind: "127.0.0.1",
      token: "test-token",
      allowedOrigins: ["http://127.0.0.1:5173"],
      requireTLS: false,
    };
    const [ownedPane] = state.listPanes();
    if (!ownedPane) {
      throw new Error("Expected seeded pane");
    }
    const unownedPane = state.createPane(ownedPane.worktreeId);

    const attached = handleControl(
      {
        v: 1,
        type: "pane.attach",
        id: makeMessageId(),
        paneId: unownedPane.id,
      },
      state,
      config,
      { ownedPaneIds: new Set([ownedPane.id]) },
    );

    expect(attached[0]?.type).toBe("error");
    if (attached[0]?.type === "error") {
      expect(attached[0].code).toBe("PANE_FORBIDDEN");
    }
  });

  test("records session ownership for panes created by that session", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-pane-create-ownership-test-"));
    const state = new InMemoryState(root, { statePath: ":memory:", spawnProcesses: false });
    const config = {
      port: 0,
      bind: "127.0.0.1",
      token: "test-token",
      allowedOrigins: ["http://127.0.0.1:5173"],
      requireTLS: false,
    };
    const ownedPaneIds = new Set<string>();

    const created = handleControl(
      {
        v: 1,
        type: "pane.create",
        id: makeMessageId(),
        worktreeId: "worktree-default",
        cols: 120,
        rows: 32,
      },
      state,
      config,
      { ownedPaneIds },
    );

    expect(created[0]?.type).toBe("pane.created");
    if (created[0]?.type === "pane.created") {
      expect(ownedPaneIds.has(created[0].paneId)).toBe(true);
    }
  });

  test("validates pane cwd stays inside the worktree", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-pane-cwd-test-"));
    mkdirSync(join(root, "inside"));
    const state = new InMemoryState(root, { statePath: ":memory:", spawnProcesses: false });
    const config = {
      port: 0,
      bind: "127.0.0.1",
      token: "test-token",
      allowedOrigins: ["http://127.0.0.1:5173"],
      requireTLS: false,
    };

    const accepted = handleControl(
      {
        v: 1,
        type: "pane.create",
        id: makeMessageId(),
        worktreeId: "worktree-default",
        cols: 120,
        rows: 32,
        cwd: "inside",
      },
      state,
      config,
    );
    const rejected = handleControl(
      {
        v: 1,
        type: "pane.create",
        id: makeMessageId(),
        worktreeId: "worktree-default",
        cols: 120,
        rows: 32,
        cwd: "..",
      },
      state,
      config,
    );

    expect(accepted[0]?.type).toBe("pane.created");
    expect(rejected[0]?.type).toBe("error");
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
    expect(archived[1]).toEqual({
      v: 1,
      type: "worktree.archiveProgress",
      id: archived[0].id,
      worktreeId: createdWorktree.id,
      step: "completed",
      message: "Worktree archived",
    });
    expect(state.worktreesByRepo.get("repo-default")?.some((worktree) => worktree.id === createdWorktree.id)).toBe(
      false,
    );
  });

  test("prefers bundled git-wt for worktree operations when available", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-git-wt-test-"));
    const repoPath = join(root, "repo");
    const logPath = join(root, "git-wt.log");
    const fakeGitWt = join(root, "git-wt");
    mkdirSync(repoPath);
    writeFileSync(
      fakeGitWt,
      `#!/bin/sh
printf "%s\\t%s\\n" "$(pwd)" "$*" >> ${JSON.stringify(logPath)}
exit 0
`,
    );
    chmodSync(fakeGitWt, 0o755);
    const previousGitWt = Bun.env.PROWL_GIT_WT_BIN;
    Bun.env.PROWL_GIT_WT_BIN = fakeGitWt;
    try {
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
          branch: "feature/git-wt-branch",
          baseRef: "main",
        },
        state,
        config,
      );
      expect(created[0]?.type).toBe("worktree.updated");
      if (created[0]?.type !== "worktree.updated") {
        throw new Error("Expected worktree.updated");
      }

      const archived = handleControl(
        {
          v: 1,
          type: "worktree.archive",
          id: makeMessageId(),
          worktreeId: created[0].worktree.id,
        },
        state,
        config,
      );
      expect(archived[0]?.type).toBe("worktree.updated");

      const log = readFileSync(logPath, "utf8");
      expect(log).toContain(`${repoPath}\tadd -b feature/git-wt-branch ${join(root, "git-wt-branch")} main\n`);
      expect(log).toContain(`${repoPath}\tremove --force ${join(root, "git-wt-branch")}\n`);
    } finally {
      if (previousGitWt === undefined) {
        Bun.env.PROWL_GIT_WT_BIN = undefined;
      } else {
        Bun.env.PROWL_GIT_WT_BIN = previousGitWt;
      }
    }
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

  test("rejects repo-scoped custom actions from another repo pane", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-action-scope-test-"));
    const otherRepo = join(root, "other");
    mkdirSync(otherRepo);
    const state = new InMemoryState(root, { statePath: ":memory:", spawnProcesses: false });
    const config = {
      port: 0,
      bind: "127.0.0.1",
      token: "test-token",
      allowedOrigins: ["http://127.0.0.1:5173"],
      requireTLS: false,
    };
    const { worktree } = state.addRepository(otherRepo);
    const pane = state.createPane(worktree.id);

    const updated = handleControl(
      {
        v: 1,
        type: "action.upsert",
        id: makeMessageId(),
        action: {
          repoId: "repo-default",
          name: "Repo only",
          command: "echo scoped",
          outputMode: "currentPane",
          ordering: 1,
        },
      },
      state,
      config,
    );
    if (updated[0]?.type !== "action.updated") {
      throw new Error("Expected action.updated");
    }
    const run = handleControl(
      {
        v: 1,
        type: "action.run",
        id: makeMessageId(),
        paneId: pane.id,
        actionId: updated[0].action.id,
      },
      state,
      config,
    );

    expect(run[0]?.type).toBe("error");
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

  test("acknowledges pane detach for existing panes", () => {
    const root = mkdtempSync(join(tmpdir(), "prowl-detach-test-"));
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

    const detached = handleControl(
      {
        v: 1,
        type: "pane.detach",
        id: makeMessageId(),
        paneId: pane.id,
      },
      state,
      config,
    );
    const missing = handleControl(
      {
        v: 1,
        type: "pane.detach",
        id: makeMessageId(),
        paneId: "missing-pane",
      },
      state,
      config,
    );

    expect(detached[0]?.type).toBe("pane.detached");
    expect(missing[0]?.type).toBe("error");
  });
});

function runGit(cwd: string, ...args: string[]): void {
  const result = Bun.spawnSync(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  if (result.exitCode !== 0) {
    throw new Error(new TextDecoder().decode(result.stderr) || new TextDecoder().decode(result.stdout));
  }
}
