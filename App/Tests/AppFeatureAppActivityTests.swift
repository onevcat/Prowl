import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import ProwlCLIShared
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

  /// `prowl <path>` adds the folder and then activates a background Prowl. The activation
  /// refresh must not cancel the add while it still resolves the folder (#1032).
  @Test(.dependencies) func becomingActiveDuringAnAddKeepsTheAdd() async {
    let existingFolder = URL(fileURLWithPath: "/tmp/prowl-activation-race/existing")
    let newFolder = URL(fileURLWithPath: "/tmp/prowl-activation-race/new")
    let fixture = OpenRaceFixture(savedFolders: [existingFolder], heldFolder: newFolder)
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [
      Repository(
        id: RepositoriesOpenReloadRaceTests.path(existingFolder),
        rootURL: existingFolder,
        name: existingFolder.lastPathComponent,
        kind: .plain,
        worktrees: []
      )
    ]
    repositories.repositoryRoots = [.local(existingFolder)]
    repositories.isInitialLoadComplete = true
    repositories.snapshotPersistencePhase = .active
    let store = TestStore(initialState: AppFeature.State(repositories: repositories)) {
      AppFeature()
    } withDependencies: {
      fixture.apply(to: &$0)
      $0.date.now = Date(timeIntervalSince1970: 1_700_000_000)
      $0[WorkflowHistoryStorageKey.self] = WorkflowHistoryStorage(
        baseURL: FileManager.default.temporaryDirectory.appending(path: "workflow-history-\(UUID().uuidString)"))
      $0.repositoryPersistence.saveLastFocusedWorktreeID = { _ in }
      $0.terminalClient.send = { _ in }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    store.timeout = .realWorkTestStoreTimeout

    await store.send(.repositories(.repositoryManagement(.openRepositories([newFolder])))) {
      $0.repositories.isOpeningRepositories = true
    }
    await fixture.heldLookup.waitUntilEntered()
    await store.send(.appActivityChanged(isActive: true))
    await store.receive(\.repositories.reloadRepositories) {
      $0.repositories.needsReloadAfterOpen = true
    }
    fixture.heldLookup.release()

    await store.receive(\.repositories.repositoryManagement.openRepositoriesFinished) {
      $0.repositories.isOpeningRepositories = false
      $0.repositories.needsReloadAfterOpen = false
      $0.repositories.repositoryRoots = [.local(existingFolder), .local(newFolder)]
    }
    await store.receive(\.repositories.reloadRepositories)
    await store.receive(\.repositories.repositoriesLoaded)
    await store.finish()

    #expect(fixture.savedPaths == [existingFolder, newFolder].map(RepositoriesOpenReloadRaceTests.path))
    #expect(store.state.repositories.repositories.ids.contains(RepositoriesOpenReloadRaceTests.path(newFolder)))
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
