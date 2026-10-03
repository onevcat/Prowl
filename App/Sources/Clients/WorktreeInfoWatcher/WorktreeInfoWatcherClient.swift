import ComposableArchitecture
import Foundation
import ProwlCLIShared

struct WorktreeInfoWatcherClient {
  var send: @MainActor @Sendable (Command) -> Void
  var events: @MainActor @Sendable () -> AsyncStream<Event>

  enum Command: Equatable {
    case setWorktrees([Worktree])
    case setOpenedWorktreeIDs(Set<Worktree.ID>)
    case setSelectedWorktreeID(Worktree.ID?)
    case refreshLineChanges
    case setPullRequestTrackingEnabled(Bool)
    case setPlainRepositoryRoots([URL])
    case stop
  }

  enum Event: Equatable {
    case branchChanged(worktreeID: Worktree.ID)
    case filesChanged(worktreeID: Worktree.ID)
    case repositoryWorktreesChanged(repositoryRootURL: URL)
    case repositoryRemoteConfigurationChanged(repositoryRootURL: URL)
    case repositoryPullRequestRefresh(repositoryRootURL: URL, worktreeIDs: [Worktree.ID])
    case plainRepositoryBecameGitRepository(URL)
  }
}

extension WorktreeInfoWatcherClient: DependencyKey {
  static let liveValue = WorktreeInfoWatcherClient(
    send: { _ in fatalError("WorktreeInfoWatcherClient.send not configured") },
    events: { fatalError("WorktreeInfoWatcherClient.events not configured") }
  )

  static let testValue = WorktreeInfoWatcherClient(
    send: { _ in },
    events: { AsyncStream { $0.finish() } }
  )
}

extension DependencyValues {
  var worktreeInfoWatcher: WorktreeInfoWatcherClient {
    get { self[WorktreeInfoWatcherClient.self] }
    set { self[WorktreeInfoWatcherClient.self] = newValue }
  }
}
