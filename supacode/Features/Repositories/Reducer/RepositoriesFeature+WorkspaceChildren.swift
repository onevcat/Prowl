import ComposableArchitecture
import Foundation

/// A workspace child repository resolved to its on-disk working directory.
/// `id` is the working-directory path string (the key for all child maps).
struct ResolvedWorkspaceChild: Equatable, Sendable, Identifiable {
  let id: String
  let workspaceID: Repository.ID
  let repositoryName: String
  let metadataBranch: String?
  let workingDirectory: URL
}

extension RepositoriesFeature {
  /// Refresh live status (current branch + uncommitted diff) for every
  /// workspace child. Driven from `repositoriesLoaded`, which fires on initial
  /// load, explicit reloads, and the periodic scene-active refresh — so child
  /// rows update on the same cadence without watching their files directly.
  ///
  /// Workspace children are deliberately NOT fed through the worktree info
  /// watcher: that pipeline bails on any worktree not tracked in
  /// `repository.worktrees`, and children are metadata entries, not tracked
  /// worktrees.
  func refreshWorkspaceChildrenEffect(state: State) -> Effect<Action> {
    let children = state.allResolvedWorkspaceChildren()
    guard !children.isEmpty else {
      return .none
    }
    let gitClient = self.gitClient
    let githubCLI = self.githubCLI
    // PR fetch only when GitHub integration is globally available; each child is
    // its own repo, so its remote is resolved from the child's own git root.
    let fetchesPullRequests = state.githubIntegrationAvailability == .available
    return .run { send in
      let updates = await withTaskGroup(of: WorkspaceChildInfoUpdate.self) { group in
        for child in children {
          group.addTask {
            async let branchTask = gitClient.branchName(child.workingDirectory)
            async let changesTask = gitClient.lineChanges(child.workingDirectory)
            let changes = await changesTask
            let branch = await branchTask
            let pullRequest = await Self.fetchWorkspaceChildPullRequest(
              workingDirectory: child.workingDirectory,
              branch: branch,
              enabled: fetchesPullRequests,
              gitClient: gitClient,
              githubCLI: githubCLI
            )
            return WorkspaceChildInfoUpdate(
              id: child.id,
              branch: branch,
              lineChanges: changes,
              pullRequest: pullRequest
            )
          }
        }
        var results: [WorkspaceChildInfoUpdate] = []
        for await update in group {
          results.append(update)
        }
        return results
      }
      await send(.workspaceChildrenInfoLoaded(updates))
    }
    .cancellable(id: CancelID.workspaceChildrenRefresh, cancelInFlight: true)
  }

  /// Resolve the child repo's GitHub remote (local-only, cheap) and fetch the
  /// PR for the current branch. Returns nil on any failure — children are
  /// best-effort status, never blocking.
  nonisolated private static func fetchWorkspaceChildPullRequest(
    workingDirectory: URL,
    branch: String?,
    enabled: Bool,
    gitClient: GitClientDependency,
    githubCLI: GithubCLIClient
  ) async -> GithubPullRequest? {
    guard enabled,
      let branch = branch?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty,
      let remote = await gitClient.remoteInfo(workingDirectory)
    else {
      return nil
    }
    let pullRequestsByBranch = try? await githubCLI.batchPullRequests(
      remote.host,
      remote.owner,
      remote.repo,
      [branch],
      nil
    )
    return pullRequestsByBranch?[branch]
  }
}

/// Merge a batch of child refresh results into the child maps.
func applyWorkspaceChildrenInfo(
  _ updates: [WorkspaceChildInfoUpdate],
  state: inout RepositoriesFeature.State
) {
  for update in updates {
    if let branch = update.branch?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty {
      state.workspaceChildBranchByID[update.id] = branch
    } else {
      state.workspaceChildBranchByID.removeValue(forKey: update.id)
    }

    var entry = state.workspaceChildInfoByID[update.id] ?? WorktreeInfoEntry()
    if let changes = update.lineChanges, !changes.isEmpty {
      entry.addedLines = changes.added
      entry.removedLines = changes.removed
    } else {
      entry.addedLines = nil
      entry.removedLines = nil
    }
    entry.skippedUntrackedFileCount = update.lineChanges?.skippedUntrackedFileCount ?? 0
    entry.pullRequest = update.pullRequest
    if entry.isEmpty {
      state.workspaceChildInfoByID.removeValue(forKey: update.id)
    } else {
      state.workspaceChildInfoByID[update.id] = entry
    }
  }
}

/// Drop child map entries that no longer belong to any current workspace.
/// Called from `applyRepositories` on every reload.
func pruneWorkspaceChildInfo(state: inout RepositoriesFeature.State) {
  let validIDs = Set(state.allResolvedWorkspaceChildren().map(\.id))
  state.workspaceChildInfoByID = state.workspaceChildInfoByID.filter { validIDs.contains($0.key) }
  state.workspaceChildBranchByID = state.workspaceChildBranchByID.filter { validIDs.contains($0.key) }
  if let selectedWorkspaceChildID = state.selectedWorkspaceChildID,
    !validIDs.contains(selectedWorkspaceChildID)
  {
    state.selectedWorkspaceChildID = nil
  }
}
