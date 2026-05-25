import type { PaneDescriptor } from "@prowl/protocol";

export class PaneManager {
  #panes = new Map<string, PaneDescriptor>();
  #nextChannelId = 1;

  create(worktreeId: string): PaneDescriptor {
    const pane: PaneDescriptor = {
      id: crypto.randomUUID(),
      channelId: this.#nextChannelId++,
      worktreeId,
      title: "Shell",
      taskStatus: "idle",
      unread: false,
      lastOutputLine: "",
      updatedAt: Date.now(),
    };
    this.#panes.set(pane.id, pane);
    return pane;
  }

  close(paneId: string): boolean {
    return this.#panes.delete(paneId);
  }

  get(paneId: string): PaneDescriptor | undefined {
    return this.#panes.get(paneId);
  }
}
