import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct AppFeatureFreestyleTerminalTests {
  @Test(.dependencies) func newTerminalInFreestyleSendsCreateTabForFreestyleWorktree() async {
    let repository = makeRepository()
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = .freestyle
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.newTerminal)
    await store.finish()

    #expect(sentCommands.value.count == 1)
    guard case .createTab(let worktree, let runSetupScriptIfNew) = sentCommands.value[0] else {
      Issue.record("Expected createTab command for freestyle new terminal")
      return
    }
    #expect(worktree.id == FreestyleTerminal.worktreeID)
    #expect(runSetupScriptIfNew == false)
  }

  @Test(.dependencies) func newTerminalFromCanvasWithoutFocusFallsBackToFreestyleAndUsesPWD() async {
    let repository = makeRepository()
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = .canvas
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.newTerminalFromCanvas(focusedWorktreeID: nil))
    await store.finish()

    #expect(sentCommands.value.count == 1)
    guard case .createTabFromCanvas(
      let worktree,
      let runSetupScriptIfNew,
      let inheritFromFocusedSurface
    ) = sentCommands.value[0]
    else {
      Issue.record("Expected createTabFromCanvas command for canvas fallback")
      return
    }
    #expect(worktree.id == FreestyleTerminal.worktreeID)
    #expect(runSetupScriptIfNew == false)
    #expect(inheritFromFocusedSurface == true)
  }

  @Test(.dependencies) func newTerminalFromCanvasUsesFocusedWorktreeAndSetupFlag() async {
    let worktree = makeWorktreeFixture()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = .canvas
    repositoriesState.pendingSetupScriptWorktreeIDs = [worktree.id]
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.newTerminalFromCanvas(focusedWorktreeID: worktree.id))
    await store.finish()

    #expect(
      sentCommands.value
        == [.createTabFromCanvas(worktree, runSetupScriptIfNew: true, inheritFromFocusedSurface: false)]
    )
  }

  @Test(.dependencies) func newTerminalFromCanvasUsingPWDUsesFocusedWorktreeAndInheritsPWD() async {
    let worktree = makeWorktreeFixture()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = .canvas
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.newTerminalFromCanvasUsingPWD(focusedWorktreeID: worktree.id))
    await store.finish()

    #expect(
      sentCommands.value
        == [.createTabFromCanvas(worktree, runSetupScriptIfNew: false, inheritFromFocusedSurface: true)]
    )
  }

  @Test(.dependencies) func selectedWorktreeChangedNilInFreestyleSetsTerminalSelectionToFreestyle() async {
    let worktree = makeWorktreeFixture()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = .freestyle
    let savedLastFocused = LockIsolated<[Worktree.ID?]>([])
    let terminalCommands = LockIsolated<[TerminalClient.Command]>([])
    let watcherCommands = LockIsolated<[WorktreeInfoWatcherClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveLastFocusedWorktreeID = { id in
        savedLastFocused.withValue { $0.append(id) }
      }
      $0.terminalClient.send = { command in
        terminalCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { command in
        watcherCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(nil))))
    await store.finish()

    #expect(savedLastFocused.value.isEmpty)
    #expect(terminalCommands.value == [.setSelectedWorktreeID(FreestyleTerminal.worktreeID)])
    #expect(watcherCommands.value == [.setSelectedWorktreeID(nil)])
  }

  private func makeRepository(worktrees: [Worktree] = [makeWorktreeFixture()]) -> Repository {
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
