import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../../daemon/src/server";
import { daemonStatus, renderDaemonStatus } from "./commands/daemon";
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
        ["bun", "run", "src/index.ts", "--json", "send", pane.id, "printf capture-smoke", "--capture"],
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
});

function runGit(cwd: string, ...args: string[]): void {
  const result = Bun.spawnSync(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  if (result.exitCode !== 0) {
    throw new Error(new TextDecoder().decode(result.stderr));
  }
}
