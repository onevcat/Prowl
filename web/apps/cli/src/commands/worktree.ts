import type { Repository, ServerControlMessage, Worktree } from "@prowl/protocol";
import { makeMessageId } from "@prowl/protocol";
import { hello, loadCLIConfig, requestDaemon } from "../transport";

export async function renderWorktreeList(repoId?: string): Promise<string> {
  const config = await loadCLIConfig();
  await hello(config.token);
  const repositories = repoId ? [{ id: repoId }] : await listRepositories();
  const worktrees = (
    await Promise.all(
      repositories.map(async (repository) => {
        const response = await requestDaemon({
          v: 1,
          type: "worktree.list",
          id: makeMessageId(),
          repoId: repository.id,
        });
        return response.type === "worktree.listed" ? response.worktrees : [];
      }),
    )
  ).flat();
  if (worktrees.length === 0) {
    return "No worktrees reported.";
  }
  return worktrees.map(formatWorktree).join("\n");
}

export async function renderWorktreeCreate(repoId: string | undefined, branch: string | undefined): Promise<string> {
  if (!repoId || !branch) {
    throw new Error("Usage: prowl worktree create <repoId> <branch>");
  }
  const config = await loadCLIConfig();
  await hello(config.token);
  const response = await requestDaemon({
    v: 1,
    type: "worktree.create",
    id: makeMessageId(),
    repoId,
    branch,
  });
  if (response.type !== "worktree.updated") {
    throw new Error(`Unexpected daemon response: ${response.type}`);
  }
  return formatWorktree(response.worktree);
}

async function listRepositories(): Promise<Array<Pick<Repository, "id">>> {
  const response = await requestDaemon({ v: 1, type: "repo.list", id: makeMessageId() });
  return response.type === "repo.listed" ? response.repositories : [];
}

function formatWorktree(worktree: Worktree): string {
  return `${worktree.id}\t${worktree.repoId}\t${worktree.branch}\t${worktree.status}\t${worktree.path}`;
}
