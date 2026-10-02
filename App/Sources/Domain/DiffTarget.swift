import Foundation

/// Stable reference to something the diff pipeline can act on: a tracked
/// worktree, or a workspace child repository. Children are scoped by their
/// workspace because metadata does not enforce path uniqueness — two open
/// workspaces may reference the same child path. `path` is the child's
/// working-directory path (the same key as `workspaceChildInfoByID`).
nonisolated enum DiffTargetID: Hashable, Sendable {
  case worktree(Worktree.ID)
  case workspaceChild(workspaceID: Repository.ID, path: String)
}

/// A resolved diff request. Separates the Git target (the directory whose
/// changes are diffed) from the terminal host (where the Hunk tool creates
/// its tab): for a workspace child the Git target is the child repository
/// while the terminal host stays the workspace, so no terminal state exists
/// outside the workspace's lifecycle.
nonisolated struct DiffTarget: Equatable, Sendable {
  let id: DiffTargetID
  /// Directory whose working-tree changes are diffed.
  let workingDirectory: URL
  /// Display branch; also fills `{branch}` in custom diff command templates.
  let branchName: String
  /// Fills `{repoPath}` in custom templates and keys `repositorySettings`.
  /// For workspace children this starts as a metadata approximation and is
  /// canonicalized by the diff effects before use.
  var repositoryRootURL: URL
  /// Worktree owning the terminal that the Hunk tool runs in.
  let terminalHost: Worktree
  /// Hunk cwd when it differs from the host's own directory.
  let terminalWorkingDirectory: URL?
}

extension DiffTarget {
  init(worktree: Worktree) {
    self.init(
      id: .worktree(worktree.id),
      workingDirectory: worktree.workingDirectory,
      branchName: worktree.name,
      repositoryRootURL: worktree.repositoryRootURL,
      terminalHost: worktree,
      terminalWorkingDirectory: nil
    )
  }
}
