import Foundation

struct ToolbarNotificationRepositoryGroup: Identifiable, Equatable {
  let id: Repository.ID
  let name: String
  let worktrees: [ToolbarNotificationWorktreeGroup]

  var notificationCount: Int {
    worktrees.reduce(0) { count, worktree in
      count + worktree.notifications.count
    }
  }

  var unseenWorktreeCount: Int {
    worktrees.reduce(0) { count, worktree in
      count + (worktree.hasUnseenNotifications ? 1 : 0)
    }
  }
}

struct ToolbarNotificationWorktreeGroup: Identifiable, Equatable {
  let id: Worktree.ID
  let name: String
  let notifications: [WorktreeTerminalNotification]
  let hasUnseenNotifications: Bool
}

extension RepositoriesFeature.State {
  /// `customTitles` is an optional per-repo display-name dictionary;
  /// when an entry exists the group's `name` uses it instead of
  /// `repository.name`. Defaults to empty for legacy callers/tests.
  func toolbarNotificationGroups(
    terminalManager: WorktreeTerminalManager,
    customTitles: [Repository.ID: String] = [:]
  ) -> [ToolbarNotificationRepositoryGroup] {
    var repositoriesByID: [Repository.ID: Repository] = [:]
    repositoriesByID.reserveCapacity(repositories.count)
    for repository in repositories {
      repositoriesByID[repository.id] = repository
    }

    var groups: [ToolbarNotificationRepositoryGroup] = []
    for repositoryID in orderedRepositoryIDs() {
      guard let repository = repositoriesByID[repositoryID] else { continue }
      let worktreeGroups = worktreeNotificationGroups(
        repository: repository,
        terminalManager: terminalManager
      )
      if !worktreeGroups.isEmpty {
        groups.append(
          ToolbarNotificationRepositoryGroup(
            id: repository.id,
            name: customTitles[repository.id] ?? repository.name,
            worktrees: worktreeGroups
          )
        )
      }
    }
    return groups
  }

  private func worktreeNotificationGroups(
    repository: Repository,
    terminalManager: WorktreeTerminalManager
  ) -> [ToolbarNotificationWorktreeGroup] {
    var result: [ToolbarNotificationWorktreeGroup] = []
    for worktree in orderedWorktrees(in: repository) {
      guard let state = terminalManager.stateIfExists(for: worktree.id),
        !state.notifications.isEmpty
      else { continue }
      result.append(
        ToolbarNotificationWorktreeGroup(
          id: worktree.id,
          name: worktree.name,
          notifications: state.notifications,
          hasUnseenNotifications: terminalManager.hasUnseenNotifications(for: worktree.id)
        )
      )
    }
    return result
  }
}
