enum SidebarSelection: Hashable {
  case worktree(Worktree.ID)
  case archivedWorktrees
  case repository(Repository.ID)
  case canvas
  case freestyle

  var worktreeID: Worktree.ID? {
    switch self {
    case .worktree(let id):
      return id
    case .archivedWorktrees, .repository, .canvas, .freestyle:
      return nil
    }
  }
}
