import type { Repository } from "@prowl/protocol";
import { makeMessageId } from "@prowl/protocol";
import { hello, loadCLIConfig, requestDaemon } from "../transport";

export async function renderRepoList(): Promise<string> {
  const config = await loadCLIConfig();
  await hello(config.token);
  const response = await requestDaemon({ v: 1, type: "repo.list", id: makeMessageId() });
  const repositories = response.type === "repo.listed" ? response.repositories : [];
  if (repositories.length === 0) {
    return "No repositories reported.";
  }
  return repositories.map(formatRepository).join("\n");
}

function formatRepository(repository: Repository): string {
  return `${repository.id}\t${repository.displayName}\t${repository.path}`;
}
