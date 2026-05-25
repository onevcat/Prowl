import type { PaneDescriptor, TaskStatus } from "./types";

export class Pane {
  readonly id: string;
  readonly channelId: number;
  readonly worktreeId: string;
  readonly term: unknown;
  title = $state("");
  taskStatus = $state<TaskStatus>("idle");
  unread = $state(false);
  output = $state("");
  lastOutputLine = $state("");
  updatedAt = $state(0);

  constructor(descriptor: PaneDescriptor, term: unknown = null) {
    this.id = descriptor.id;
    this.channelId = descriptor.channelId;
    this.worktreeId = descriptor.worktreeId;
    this.term = term;
    this.title = descriptor.title;
    this.taskStatus = descriptor.taskStatus;
    this.unread = descriptor.unread;
    this.output = descriptor.lastOutputLine;
    this.lastOutputLine = descriptor.lastOutputLine;
    this.updatedAt = descriptor.updatedAt;
  }

  get descriptor(): PaneDescriptor {
    return {
      id: this.id,
      channelId: this.channelId,
      worktreeId: this.worktreeId,
      title: this.title,
      taskStatus: this.taskStatus,
      unread: this.unread,
      lastOutputLine: this.lastOutputLine,
      updatedAt: this.updatedAt,
    };
  }
}
