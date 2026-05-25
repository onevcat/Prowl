import type { PaneDescriptor, ServerControlMessage } from "@prowl/protocol";
import { makeMessageId } from "@prowl/protocol";
import { hello, loadCLIConfig, requestDaemon } from "../transport";

export async function renderList(): Promise<string> {
  const panes = await getPaneList();
  if (panes.length === 0) {
    return "No panes reported.";
  }
  return panes.map((pane) => `${pane.id}\t${pane.worktreeId}\t${pane.taskStatus}\t${pane.title}`).join("\n");
}

export async function getPaneList(): Promise<PaneDescriptor[]> {
  const config = await loadCLIConfig();
  await hello(config.token);
  const response = await requestDaemon({
    v: 1,
    type: "settings.get",
    id: makeMessageId(),
    keys: ["panes"],
  });
  return panesFromResponse(response);
}

function panesFromResponse(response: ServerControlMessage): PaneDescriptor[] {
  if (response.type !== "settings.snapshot" || !Array.isArray(response.settings.panes)) {
    return [];
  }
  return response.settings.panes as PaneDescriptor[];
}
