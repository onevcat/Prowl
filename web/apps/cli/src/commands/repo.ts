import type { Repository } from "@prowl/protocol";
import { makeMessageId } from "@prowl/protocol";
import { hello, loadCLIConfig, requestDaemon } from "../transport";

export async function renderRepoList(): Promise<string> {
  const repositories = await getRepositoryList();
  if (repositories.length === 0) {
    return "No repositories reported.";
  }
  return repositories.map(formatRepository).join("\n");
}

export async function getRepositoryList(): Promise<Repository[]> {
  const config = await loadCLIConfig();
  await hello(config.token);
  const response = await requestDaemon({ v: 1, type: "repo.list", id: makeMessageId() });
  return response.type === "repo.listed" ? response.repositories : [];
}

export async function renderRepoAdd(path: string | undefined): Promise<string> {
  return formatRepository(await addRepository(path));
}

export async function addRepository(path: string | undefined): Promise<Repository> {
  const normalizedPath = path?.trim();
  if (!normalizedPath) {
    throw new Error("Usage: prowl repo add <path>");
  }
  const config = await loadCLIConfig();
  await hello(config.token);
  const response = await requestDaemon({
    v: 1,
    type: "repo.add",
    id: makeMessageId(),
    path: normalizedPath,
  });
  if (response.type !== "repo.updated") {
    throw new Error(`Unexpected daemon response: ${response.type}`);
  }
  return response.repository;
}

export async function renderRepoRemove(repoId: string | undefined): Promise<string> {
  await removeRepository(repoId);
  return `removed\t${repoId}`;
}

export async function removeRepository(repoId: string | undefined): Promise<Repository[]> {
  if (!repoId) {
    throw new Error("Usage: prowl repo remove <repoId>");
  }
  const config = await loadCLIConfig();
  await hello(config.token);
  const response = await requestDaemon({
    v: 1,
    type: "repo.remove",
    id: makeMessageId(),
    repoId,
  });
  if (response.type !== "repo.listed") {
    throw new Error(`Unexpected daemon response: ${response.type}`);
  }
  return response.repositories;
}

export function formatRepository(repository: Repository): string {
  return `${repository.id}\t${repository.displayName}\t${repository.path}`;
}
