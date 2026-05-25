import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../../daemon/src/server";
import { daemonStart, daemonStatus, daemonStop, renderDaemonStatus } from "./commands/daemon";
import { renderVersion } from "./commands/version";
import { requestDaemon } from "./transport";

describe("prowl cli scaffold", () => {
  test("renders version", () => {
    expect(renderVersion()).toBe("prowl 0.0.0");
  });

  test("renders JSON output for machine consumers", () => {
    const result = Bun.spawnSync(["bun", "run", "src/index.ts", "--json", "version"], {
      cwd: new URL("..", import.meta.url).pathname,
      stdout: "pipe",
      stderr: "pipe",
    });

    expect(result.exitCode).toBe(0);
    expect(JSON.parse(new TextDecoder().decode(result.stdout))).toEqual({ name: "prowl", version: "0.0.0" });
  });

  test("renders daemon status", async () => {
    const text = await renderDaemonStatus();

    expect(text).toMatch(/running|stopped/);
    expect(text).toContain("prowld.sock");
  });

  test("reads daemon status from configured CLI paths", async () => {
    const token = "test-token";
    const previousConfigPath = Bun.env.PROWL_CONFIG_PATH;
    const previousSocketPath = Bun.env.PROWL_SOCKET_PATH;
    const home = mkdtempSync(join(tmpdir(), "prowl-cli-status-home-"));
    const prowlHome = join(home, ".prowl");
    mkdirSync(prowlHome, { recursive: true });
    writeFileSync(
      join(prowlHome, "config.json"),
      JSON.stringify({
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      }),
    );
    const socketPath = join(prowlHome, "prowld.sock");
    Bun.env.PROWL_CONFIG_PATH = join(prowlHome, "config.json");
    Bun.env.PROWL_SOCKET_PATH = socketPath;
    const server = startServer(
      {
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      },
      { socketPath, statePath: join(prowlHome, "state.sqlite"), spawnProcesses: false },
    );

    try {
      await Bun.sleep(50);
      const status = await daemonStatus();

      expect(status.running).toBe(true);
      expect(status.socketPath).toBe(socketPath);
    } finally {
      server.stop();
      if (previousConfigPath === undefined) {
        Bun.env.PROWL_CONFIG_PATH = undefined;
      } else {
        Bun.env.PROWL_CONFIG_PATH = previousConfigPath;
      }
      if (previousSocketPath === undefined) {
        Bun.env.PROWL_SOCKET_PATH = undefined;
      } else {
        Bun.env.PROWL_SOCKET_PATH = previousSocketPath;
      }
    }
  });

  test("starts the daemon only after the local socket is ready", async () => {
    const token = "test-token";
    const previousConfigPath = Bun.env.PROWL_CONFIG_PATH;
    const previousSocketPath = Bun.env.PROWL_SOCKET_PATH;
    const previousRepoRoot = Bun.env.PROWL_REPO_ROOT;
    const previousDaemonBin = Bun.env.PROWL_DAEMON_BIN;
    const home = mkdtempSync(join(tmpdir(), "prowl-cli-start-home-"));
    const prowlHome = join(home, ".prowl");
    const repoRoot = join(home, "repo");
    const daemonShim = join(home, "prowld-source.sh");
    mkdirSync(prowlHome, { recursive: true });
    mkdirSync(repoRoot);
    writeFileSync(
      daemonShim,
      `#!/bin/sh
exec bun run apps/daemon/src/index.ts
`,
    );
    chmodSync(daemonShim, 0o755);
    writeFileSync(
      join(prowlHome, "config.json"),
      JSON.stringify({
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      }),
    );
    Bun.env.PROWL_CONFIG_PATH = join(prowlHome, "config.json");
    Bun.env.PROWL_SOCKET_PATH = join(prowlHome, "prowld.sock");
    Bun.env.PROWL_REPO_ROOT = repoRoot;
    Bun.env.PROWL_DAEMON_BIN = daemonShim;

    try {
      const started = await daemonStart();
      const status = await daemonStatus();

      expect(started.running).toBe(true);
      expect(started.message).toBe("started");
      expect(status.running).toBe(true);
      expect(status.pid).toBe(started.pid);
    } finally {
      await daemonStop();
      if (previousConfigPath === undefined) {
        Bun.env.PROWL_CONFIG_PATH = undefined;
      } else {
        Bun.env.PROWL_CONFIG_PATH = previousConfigPath;
      }
      if (previousSocketPath === undefined) {
        Bun.env.PROWL_SOCKET_PATH = undefined;
      } else {
        Bun.env.PROWL_SOCKET_PATH = previousSocketPath;
      }
      if (previousRepoRoot === undefined) {
        Bun.env.PROWL_REPO_ROOT = undefined;
      } else {
        Bun.env.PROWL_REPO_ROOT = previousRepoRoot;
      }
      if (previousDaemonBin === undefined) {
        Bun.env.PROWL_DAEMON_BIN = undefined;
      } else {
        Bun.env.PROWL_DAEMON_BIN = previousDaemonBin;
      }
    }
  });

  test("adds and removes repositories through the CLI", async () => {
    const token = "test-token";
    const home = mkdtempSync(join(tmpdir(), "prowl-cli-repo-home-"));
    const prowlHome = join(home, ".prowl");
    mkdirSync(prowlHome, { recursive: true });
    writeFileSync(
      join(prowlHome, "config.json"),
      JSON.stringify({
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      }),
    );
    const socketPath = join(prowlHome, "prowld.sock");
    const repositoryPath = mkdtempSync(join(tmpdir(), "prowl-cli-repo-"));
    const server = startServer(
      {
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      },
      { socketPath, statePath: join(prowlHome, "state.sqlite"), spawnProcesses: false },
    );

    try {
      await Bun.sleep(50);
      const addResult = Bun.spawn(["bun", "run", "src/index.ts", "--json", "repo", "add", repositoryPath], {
        cwd: new URL("..", import.meta.url).pathname,
        env: {
          ...Bun.env,
          PROWL_CONFIG_PATH: join(prowlHome, "config.json"),
          PROWL_SOCKET_PATH: socketPath,
        },
        stdout: "pipe",
        stderr: "pipe",
      });
      const [addExitCode, addStdout, addStderr] = await Promise.all([
        addResult.exited,
        new Response(addResult.stdout).text(),
        new Response(addResult.stderr).text(),
      ]);

      expect(addExitCode).toBe(0);
      expect(addStderr).toBe("");
      const repository = JSON.parse(addStdout) as { id: string; path: string };
      expect(repository.path).toBe(repositoryPath);

      const removeResult = Bun.spawn(["bun", "run", "src/index.ts", "--json", "repo", "remove", repository.id], {
        cwd: new URL("..", import.meta.url).pathname,
        env: {
          ...Bun.env,
          PROWL_CONFIG_PATH: join(prowlHome, "config.json"),
          PROWL_SOCKET_PATH: socketPath,
        },
        stdout: "pipe",
        stderr: "pipe",
      });
      const [removeExitCode, removeStdout, removeStderr] = await Promise.all([
        removeResult.exited,
        new Response(removeResult.stdout).text(),
        new Response(removeResult.stderr).text(),
      ]);

      expect(removeExitCode).toBe(0);
      expect(removeStderr).toBe("");
      const repositories = JSON.parse(removeStdout) as Array<{ id: string }>;
      expect(repositories.some((candidate) => candidate.id === repository.id)).toBe(false);
    } finally {
      server.stop();
    }
  });

  test("reads worktree diff through the CLI", async () => {
    const token = "test-token";
    const home = mkdtempSync(join(tmpdir(), "prowl-cli-diff-home-"));
    const prowlHome = join(home, ".prowl");
    const repoPath = join(home, "repo");
    mkdirSync(prowlHome, { recursive: true });
    mkdirSync(repoPath);
    runGit(repoPath, "init");
    writeFileSync(join(repoPath, "README.md"), "before\n");
    runGit(repoPath, "add", "README.md");
    runGit(repoPath, "-c", "user.name=Prowl Test", "-c", "user.email=prowl@example.com", "commit", "-m", "initial");
    writeFileSync(join(repoPath, "README.md"), "after\n");
    writeFileSync(
      join(prowlHome, "config.json"),
      JSON.stringify({
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      }),
    );
    const previousRepoRoot = Bun.env.PROWL_REPO_ROOT;
    const socketPath = join(prowlHome, "prowld.sock");
    Bun.env.PROWL_REPO_ROOT = repoPath;
    const server = startServer(
      {
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      },
      { socketPath, statePath: join(prowlHome, "state.sqlite"), spawnProcesses: false },
    );

    try {
      await Bun.sleep(50);
      const result = Bun.spawn(["bun", "run", "src/index.ts", "--json", "worktree", "diff", "worktree-default"], {
        cwd: new URL("..", import.meta.url).pathname,
        env: {
          ...Bun.env,
          PROWL_CONFIG_PATH: join(prowlHome, "config.json"),
          PROWL_SOCKET_PATH: socketPath,
        },
        stdout: "pipe",
        stderr: "pipe",
      });
      const [exitCode, stdout, stderr] = await Promise.all([
        result.exited,
        new Response(result.stdout).text(),
        new Response(result.stderr).text(),
      ]);

      expect(exitCode).toBe(0);
      expect(stderr).toBe("");
      const diff = JSON.parse(stdout) as { text: string; worktreeId: string };
      expect(diff.worktreeId).toBe("worktree-default");
      expect(diff.text).toContain("-before");
      expect(diff.text).toContain("+after");
    } finally {
      server.stop();
      if (previousRepoRoot === undefined) {
        Bun.env.PROWL_REPO_ROOT = undefined;
      } else {
        Bun.env.PROWL_REPO_ROOT = previousRepoRoot;
      }
    }
  });

  test("archives a worktree through the CLI", async () => {
    const token = "test-token";
    const home = mkdtempSync(join(tmpdir(), "prowl-cli-archive-home-"));
    const prowlHome = join(home, ".prowl");
    const repoPath = join(home, "repo");
    mkdirSync(prowlHome, { recursive: true });
    mkdirSync(repoPath);
    runGit(repoPath, "init");
    writeFileSync(join(repoPath, "README.md"), "archive\n");
    runGit(repoPath, "add", "README.md");
    runGit(repoPath, "-c", "user.name=Prowl Test", "-c", "user.email=prowl@example.com", "commit", "-m", "initial");
    writeFileSync(
      join(prowlHome, "config.json"),
      JSON.stringify({
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      }),
    );
    const previousRepoRoot = Bun.env.PROWL_REPO_ROOT;
    const socketPath = join(prowlHome, "prowld.sock");
    Bun.env.PROWL_REPO_ROOT = repoPath;
    const server = startServer(
      {
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      },
      { socketPath, statePath: join(prowlHome, "state.sqlite"), spawnProcesses: false },
    );

    try {
      await Bun.sleep(50);
      const createResult = Bun.spawn(
        ["bun", "run", "src/index.ts", "--json", "worktree", "create", "repo-default", "feature/archive"],
        {
          cwd: new URL("..", import.meta.url).pathname,
          env: {
            ...Bun.env,
            PROWL_CONFIG_PATH: join(prowlHome, "config.json"),
            PROWL_SOCKET_PATH: socketPath,
          },
          stdout: "pipe",
          stderr: "pipe",
        },
      );
      const [createExitCode, createStdout, createStderr] = await Promise.all([
        createResult.exited,
        new Response(createResult.stdout).text(),
        new Response(createResult.stderr).text(),
      ]);
      expect(createExitCode).toBe(0);
      expect(createStderr).toBe("");
      const created = JSON.parse(createStdout) as { id: string; status: string };

      const archiveResult = Bun.spawn(["bun", "run", "src/index.ts", "--json", "worktree", "archive", created.id], {
        cwd: new URL("..", import.meta.url).pathname,
        env: {
          ...Bun.env,
          PROWL_CONFIG_PATH: join(prowlHome, "config.json"),
          PROWL_SOCKET_PATH: socketPath,
        },
        stdout: "pipe",
        stderr: "pipe",
      });
      const [archiveExitCode, archiveStdout, archiveStderr] = await Promise.all([
        archiveResult.exited,
        new Response(archiveResult.stdout).text(),
        new Response(archiveResult.stderr).text(),
      ]);

      expect(archiveExitCode).toBe(0);
      expect(archiveStderr).toBe("");
      const archived = JSON.parse(archiveStdout) as { id: string; status: string; taskStatus: string };
      expect(archived.id).toBe(created.id);
      expect(archived.status).toBe("archived");
      expect(archived.taskStatus).toBe("done");
    } finally {
      server.stop();
      if (previousRepoRoot === undefined) {
        Bun.env.PROWL_REPO_ROOT = undefined;
      } else {
        Bun.env.PROWL_REPO_ROOT = previousRepoRoot;
      }
    }
  });

  test("creates a worktree with CLI directory and base ref options", async () => {
    const token = "test-token";
    const home = mkdtempSync(join(tmpdir(), "prowl-cli-worktree-options-home-"));
    const prowlHome = join(home, ".prowl");
    const repoPath = join(home, "repo");
    mkdirSync(prowlHome, { recursive: true });
    mkdirSync(repoPath);
    runGit(repoPath, "init");
    writeFileSync(join(repoPath, "README.md"), "options\n");
    runGit(repoPath, "add", "README.md");
    runGit(repoPath, "-c", "user.name=Prowl Test", "-c", "user.email=prowl@example.com", "commit", "-m", "initial");
    writeFileSync(
      join(prowlHome, "config.json"),
      JSON.stringify({
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      }),
    );
    const previousRepoRoot = Bun.env.PROWL_REPO_ROOT;
    const socketPath = join(prowlHome, "prowld.sock");
    Bun.env.PROWL_REPO_ROOT = repoPath;
    const server = startServer(
      {
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      },
      { socketPath, statePath: join(prowlHome, "state.sqlite"), spawnProcesses: false },
    );

    try {
      await Bun.sleep(50);
      const result = Bun.spawn(
        [
          "bun",
          "run",
          "src/index.ts",
          "--json",
          "worktree",
          "create",
          "repo-default",
          "feature/options",
          "--base-ref",
          "HEAD",
          "--directory",
          "custom-worktree",
        ],
        {
          cwd: new URL("..", import.meta.url).pathname,
          env: {
            ...Bun.env,
            PROWL_CONFIG_PATH: join(prowlHome, "config.json"),
            PROWL_SOCKET_PATH: socketPath,
          },
          stdout: "pipe",
          stderr: "pipe",
        },
      );
      const [exitCode, stdout, stderr] = await Promise.all([
        result.exited,
        new Response(result.stdout).text(),
        new Response(result.stderr).text(),
      ]);

      expect(exitCode).toBe(0);
      expect(stderr).toBe("");
      const created = JSON.parse(stdout) as { branch: string; path: string };
      expect(created.branch).toBe("feature/options");
      expect(created.path).toBe(join(home, "custom-worktree"));
    } finally {
      server.stop();
      if (previousRepoRoot === undefined) {
        Bun.env.PROWL_REPO_ROOT = undefined;
      } else {
        Bun.env.PROWL_REPO_ROOT = previousRepoRoot;
      }
    }
  });

  test("creates a pane with an initial command through the CLI", async () => {
    const token = "test-token";
    const home = mkdtempSync(join(tmpdir(), "prowl-cli-new-home-"));
    const prowlHome = join(home, ".prowl");
    mkdirSync(prowlHome, { recursive: true });
    writeFileSync(
      join(prowlHome, "config.json"),
      JSON.stringify({
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      }),
    );
    const socketPath = join(prowlHome, "prowld.sock");
    const server = startServer(
      {
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      },
      { socketPath, statePath: join(prowlHome, "state.sqlite"), spawnProcesses: true },
    );

    try {
      await Bun.sleep(50);
      const newResult = Bun.spawn(
        [
          "bun",
          "run",
          "src/index.ts",
          "--json",
          "new",
          "--worktree",
          "worktree-default",
          "--command",
          "printf cli-new-pane",
        ],
        {
          cwd: new URL("..", import.meta.url).pathname,
          env: {
            ...Bun.env,
            PROWL_CONFIG_PATH: join(prowlHome, "config.json"),
            PROWL_SOCKET_PATH: socketPath,
          },
          stdout: "pipe",
          stderr: "pipe",
        },
      );
      const [newExitCode, newStdout, newStderr] = await Promise.all([
        newResult.exited,
        new Response(newResult.stdout).text(),
        new Response(newResult.stderr).text(),
      ]);

      expect(newExitCode).toBe(0);
      expect(newStderr).toBe("");
      const pane = JSON.parse(newStdout) as { paneId: string; worktreeId: string; channelId: number };
      expect(pane.worktreeId).toBe("worktree-default");
      expect(pane.channelId).toBeGreaterThan(0);

      await Bun.sleep(250);
      const readResult = Bun.spawn(["bun", "run", "src/index.ts", "--json", "read", pane.paneId], {
        cwd: new URL("..", import.meta.url).pathname,
        env: {
          ...Bun.env,
          PROWL_CONFIG_PATH: join(prowlHome, "config.json"),
          PROWL_SOCKET_PATH: socketPath,
        },
        stdout: "pipe",
        stderr: "pipe",
      });
      const [readExitCode, readStdout, readStderr] = await Promise.all([
        readResult.exited,
        new Response(readResult.stdout).text(),
        new Response(readResult.stderr).text(),
      ]);

      expect(readExitCode).toBe(0);
      expect(readStderr).toBe("");
      const replay = JSON.parse(readStdout) as { output: string };
      expect(replay.output).toContain("cli-new-pane");
    } finally {
      server.stop();
    }
  });

  test("captures send output in JSON mode", async () => {
    const token = "test-token";
    const home = mkdtempSync(join(tmpdir(), "prowl-cli-home-"));
    const prowlHome = join(home, ".prowl");
    mkdirSync(prowlHome, { recursive: true });
    writeFileSync(
      join(prowlHome, "config.json"),
      JSON.stringify({
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      }),
    );
    const socketPath = join(prowlHome, "prowld.sock");
    const server = startServer(
      {
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      },
      { socketPath, statePath: join(prowlHome, "state.sqlite"), spawnProcesses: true },
    );

    try {
      await Bun.sleep(50);
      const panes = await requestDaemon(
        {
          v: 1,
          type: "settings.get",
          id: crypto.randomUUID(),
          keys: ["panes"],
        },
        socketPath,
      );
      if (panes.type !== "settings.snapshot" || !Array.isArray(panes.settings.panes)) {
        throw new Error("Expected panes");
      }
      const pane = panes.settings.panes[0];
      const result = Bun.spawn(
        ["bun", "run", "src/index.ts", "--json", "send", pane.id, "sleep 0.4; printf capture-smoke", "--capture"],
        {
          cwd: new URL("..", import.meta.url).pathname,
          env: {
            ...Bun.env,
            PROWL_CONFIG_PATH: join(prowlHome, "config.json"),
            PROWL_SOCKET_PATH: socketPath,
          },
          stdout: "pipe",
          stderr: "pipe",
        },
      );
      const [exitCode, stdout, stderr] = await Promise.all([
        result.exited,
        new Response(result.stdout).text(),
        new Response(result.stderr).text(),
      ]);

      expect(exitCode).toBe(0);
      expect(stderr).toBe("");
      const output = JSON.parse(stdout);
      expect(output.output).toContain("capture-smoke");
    } finally {
      server.stop();
    }
  });

  test("sends a pane command once in human-readable mode", async () => {
    const token = "test-token";
    const home = mkdtempSync(join(tmpdir(), "prowl-cli-human-home-"));
    const prowlHome = join(home, ".prowl");
    mkdirSync(prowlHome, { recursive: true });
    writeFileSync(
      join(prowlHome, "config.json"),
      JSON.stringify({
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      }),
    );
    const socketPath = join(prowlHome, "prowld.sock");
    const outputPath = join(home, "send-once.txt");
    writeFileSync(outputPath, "");
    const server = startServer(
      {
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      },
      { socketPath, statePath: join(prowlHome, "state.sqlite"), spawnProcesses: true },
    );

    try {
      await Bun.sleep(50);
      const panes = await requestDaemon(
        {
          v: 1,
          type: "settings.get",
          id: crypto.randomUUID(),
          keys: ["panes"],
        },
        socketPath,
      );
      if (panes.type !== "settings.snapshot" || !Array.isArray(panes.settings.panes)) {
        throw new Error("Expected panes");
      }
      const pane = panes.settings.panes[0];
      const result = Bun.spawn(["bun", "run", "src/index.ts", "send", pane.id, `printf x >> ${outputPath}`], {
        cwd: new URL("..", import.meta.url).pathname,
        env: {
          ...Bun.env,
          PROWL_CONFIG_PATH: join(prowlHome, "config.json"),
          PROWL_SOCKET_PATH: socketPath,
        },
        stdout: "pipe",
        stderr: "pipe",
      });
      const [exitCode, stdout, stderr] = await Promise.all([
        result.exited,
        new Response(result.stdout).text(),
        new Response(result.stderr).text(),
      ]);

      expect(exitCode).toBe(0);
      expect(stderr).toBe("");
      expect(stdout.trim()).toBe(`sent\t${pane.id}`);
      await Bun.sleep(250);
      expect(readFileSync(outputPath, "utf8")).toBe("x");
    } finally {
      server.stop();
    }
  });

  test("sends pane keystrokes through the CLI", async () => {
    const token = "test-token";
    const home = mkdtempSync(join(tmpdir(), "prowl-cli-key-home-"));
    const prowlHome = join(home, ".prowl");
    mkdirSync(prowlHome, { recursive: true });
    writeFileSync(
      join(prowlHome, "config.json"),
      JSON.stringify({
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      }),
    );
    const socketPath = join(prowlHome, "prowld.sock");
    const server = startServer(
      {
        port: 0,
        bind: "127.0.0.1",
        token,
        allowedOrigins: ["http://127.0.0.1:5173"],
        requireTLS: false,
      },
      { socketPath, statePath: join(prowlHome, "state.sqlite"), spawnProcesses: true },
    );
    const cliEnv = {
      ...Bun.env,
      PROWL_CONFIG_PATH: join(prowlHome, "config.json"),
      PROWL_SOCKET_PATH: socketPath,
    };

    try {
      await Bun.sleep(50);
      const panes = await requestDaemon(
        {
          v: 1,
          type: "settings.get",
          id: crypto.randomUUID(),
          keys: ["panes"],
        },
        socketPath,
      );
      if (panes.type !== "settings.snapshot" || !Array.isArray(panes.settings.panes)) {
        throw new Error("Expected panes");
      }
      const pane = panes.settings.panes[0];
      const typed = Bun.spawn(["bun", "run", "src/index.ts", "--json", "key", pane.id, "printf cli-key"], {
        cwd: new URL("..", import.meta.url).pathname,
        env: cliEnv,
        stdout: "pipe",
        stderr: "pipe",
      });
      const [typedExitCode, typedStdout, typedStderr] = await Promise.all([
        typed.exited,
        new Response(typed.stdout).text(),
        new Response(typed.stderr).text(),
      ]);

      expect(typedExitCode).toBe(0);
      expect(typedStderr).toBe("");
      expect(JSON.parse(typedStdout)).toEqual({ paneId: pane.id, status: "sent", key: "printf cli-key" });

      const entered = Bun.spawn(["bun", "run", "src/index.ts", "--json", "key", pane.id, "Enter"], {
        cwd: new URL("..", import.meta.url).pathname,
        env: cliEnv,
        stdout: "pipe",
        stderr: "pipe",
      });
      const [enteredExitCode, enteredStderr] = await Promise.all([entered.exited, new Response(entered.stderr).text()]);

      expect(enteredExitCode).toBe(0);
      expect(enteredStderr).toBe("");

      await Bun.sleep(250);
      const readResult = Bun.spawn(["bun", "run", "src/index.ts", "--json", "read", pane.id], {
        cwd: new URL("..", import.meta.url).pathname,
        env: cliEnv,
        stdout: "pipe",
        stderr: "pipe",
      });
      const [readExitCode, readStdout, readStderr] = await Promise.all([
        readResult.exited,
        new Response(readResult.stdout).text(),
        new Response(readResult.stderr).text(),
      ]);

      expect(readExitCode).toBe(0);
      expect(readStderr).toBe("");
      const replay = JSON.parse(readStdout) as { output: string };
      expect(replay.output).toContain("cli-key");
    } finally {
      server.stop();
    }
  });
});

function runGit(cwd: string, ...args: string[]): void {
  const result = Bun.spawnSync(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  if (result.exitCode !== 0) {
    throw new Error(new TextDecoder().decode(result.stderr));
  }
}
