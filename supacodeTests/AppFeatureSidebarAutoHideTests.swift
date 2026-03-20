import Clocks
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct AppFeatureSidebarAutoHideTests {
  @Test(.dependencies) func enteringCanvasAutoHidesSidebarAfterDelay() async {
    let clock = TestClock()
    let defaults = UserDefaults(suiteName: "AppFeatureSidebarAutoHideTests.enteringCanvasAutoHide")!
    defaults.removePersistentDomain(forName: "AppFeatureSidebarAutoHideTests.enteringCanvasAutoHide")
    let worktree = makeWorktreeFixture()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = .worktree(worktree.id)
    let appState = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State()
    )
    let store = TestStore(initialState: appState) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.defaultAppStorage = defaults
      $0.terminalClient.send = { _ in }
    }

    await store.send(.setLeftSidebarHidden(false)) { state in
      state.$isLeftSidebarHidden.withLock { $0 = false }
    }
    #expect(store.state.isLeftSidebarHidden == false)

    await store.send(.repositories(.selectCanvas)) {
      $0.repositories.preCanvasWorktreeID = worktree.id
      $0.repositories.preCanvasTerminalTargetID = worktree.id
      $0.repositories.canvasReturnWorktreeID = worktree.id
      $0.repositories.selection = .canvas
      $0.repositories.sidebarSelectedWorktreeIDs = []
    }
    #expect(store.state.isLeftSidebarHidden == false)

    await clock.advance(by: .seconds(3))
    await store.receive(\.canvasSidebarAutoHideDelayElapsed) { state in
      state.$isLeftSidebarHidden.withLock { $0 = true }
    }
  }

  @Test(.dependencies) func exitingCanvasBeforeDelayDoesNotHideSidebar() async {
    let clock = TestClock()
    let defaults = UserDefaults(suiteName: "AppFeatureSidebarAutoHideTests.exitingCanvasAutoHide")!
    defaults.removePersistentDomain(forName: "AppFeatureSidebarAutoHideTests.exitingCanvasAutoHide")
    let worktree = makeWorktreeFixture()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = .worktree(worktree.id)
    let appState = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State()
    )
    let store = TestStore(initialState: appState) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.defaultAppStorage = defaults
      $0.terminalClient.send = { _ in }
      $0.worktreeInfoWatcher.send = { _ in }
      $0.repositoryPersistence.saveLastFocusedWorktreeID = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.setLeftSidebarHidden(false)) { state in
      state.$isLeftSidebarHidden.withLock { $0 = false }
    }

    await store.send(.repositories(.selectCanvas))
    await store.send(.repositories(.selectWorktree(worktree.id)))
    await clock.advance(by: .seconds(3))

    #expect(store.state.isLeftSidebarHidden == false)
  }

  private func makeRepository(worktrees: [Worktree]) -> Repository {
    let rootURL = URL(fileURLWithPath: "/tmp/repo", isDirectory: true)
    return Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: rootURL.lastPathComponent,
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }
}

private func makeWorktreeFixture() -> Worktree {
  Worktree(
    id: "/tmp/repo/wt-1",
    name: "wt-1",
    detail: "",
    workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
    repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
  )
}
