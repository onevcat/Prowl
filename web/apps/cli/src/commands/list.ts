import type { PaneDescriptor, ServerControlMessage } from "@prowl/protocol";
import { makeMessageId } from "@prowl/protocol";
import { formatPane } from "../output";
import { hello, loadCLIConfig, requestDaemon } from "../transport";

export async function renderList(): Promise<string> {
  const panes = await getPaneList();
  if (panes.length === 0) {
    return "No panes reported.";
  }
  return panes.map(formatPane).join("\n");
}

export async function getPaneList(): Promise<PaneDescriptor[]> {
  const config = await loadCLIConfig();
  await hello(config.token);
  const response = await requestDaemon({
    v: 1,
    type: "pane.list",
    id: makeMessageId(),
  });
  return panesFromResponse(response);
}

function panesFromResponse(response: ServerControlMessage): PaneDescriptor[] {
  if (response.type !== "pane.listed") {
    return [];
  }
  return response.panes;
}
