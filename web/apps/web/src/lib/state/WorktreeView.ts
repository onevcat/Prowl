export class WorktreeView {
  readonly worktreeId: string;
  selectedPaneId = $state<string | null>(null);
  scrollTop = $state(0);

  constructor(worktreeId: string) {
    this.worktreeId = worktreeId;
  }
}
