import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import Prowl

@MainActor
struct AppFeatureAppActivityTests {
  @Test(.dependencies) func becomingActiveReloadsRepositoriesAndResumesRemotePolls() async {
    var repositories = RepositoriesFeature.State()
    repositories.isInitialLoadComplete = true
    repositories.isRemoteRefreshPaused = true
    let watcherCommands = LockIsolated<[WorktreeInfoWatcherClient.Command]>([])
    let store = TestStore(initialState: AppFeature.State(repositories: repositories)) {
      AppFeature()
    } withDependencies: {
      $0.worktreeInfoWatcher.send = { command in
        watcherCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.appActivityChanged(isActive: true))
    await store.receive(\.repositories.setRemoteRefreshActive) {
      $0.repositories.isRemoteRefreshPaused = false
    }
    await store.receive(\.repositories.reloadRepositories)
    // No timer stays behind: the store must finish with no effect in flight.
    await store.finish()

    #expect(watcherCommands.value == [.refreshLineChanges])
  }

  @Test(.dependencies) func becomingActiveBeforeTheInitialLoadSkipsTheReload() async {
    var repositories = RepositoriesFeature.State()
    repositories.isRemoteRefreshPaused = true
    let store = TestStore(initialState: AppFeature.State(repositories: repositories)) {
      AppFeature()
    } withDependencies: {
      $0.worktreeInfoWatcher.send = { _ in }
    }

    await store.send(.appActivityChanged(isActive: true))
    await store.receive(\.repositories.setRemoteRefreshActive) {
      $0.repositories.isRemoteRefreshPaused = false
    }
    await store.finish()
  }

  @Test(.dependencies) func resigningActivePausesRemotePolls() async {
    var repositories = RepositoriesFeature.State()
    repositories.isInitialLoadComplete = true
    let store = TestStore(initialState: AppFeature.State(repositories: repositories)) {
      AppFeature()
    }

    await store.send(.appActivityChanged(isActive: false))
    await store.receive(\.repositories.setRemoteRefreshActive) {
      $0.repositories.isRemoteRefreshPaused = true
    }
    await store.finish()
  }
}
