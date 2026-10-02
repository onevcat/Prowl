import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct AppFeatureTerminalSetupScriptTests {
  @Test(.dependencies) func newTerminalConsumesSetupScriptAndSendsCreateTabWithFlag() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: true,
      selected: true
    )
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.newTerminal)
    await store.send(.terminalEvent(.setupScriptConsumed(worktreeID: worktree.id)))
    await store.receive(\.repositories.worktreeCreation.consumeSetupScript) {
      $0.repositories.pendingSetupScriptWorktreeIDs.remove(worktree.id)
    }
    await store.finish()
    #expect(sent.value == [.createTab(worktree, runSetupScriptIfNew: true)])
  }

  @Test(.dependencies) func newTerminalWithoutSetupScriptDoesNotConsume() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: false,
      selected: true
    )
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.newTerminal)
    await store.finish()
    #expect(sent.value == [.createTab(worktree, runSetupScriptIfNew: false)])
  }

  @Test(.dependencies) func tabCreatedDoesNotConsumeSetupScript() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: true,
      selected: true
    )
    let watcherCommands = LockIsolated<[WorktreeInfoWatcherClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.worktreeInfoWatcher.send = { command in
        watcherCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.terminalEvent(.tabCreated(worktreeID: worktree.id)))
    await store.receive(\.repositories.markWorktreeOpened) {
      $0.repositories.openedWorktreeIDs = [worktree.id]
    }
    #expect(store.state.repositories.pendingSetupScriptWorktreeIDs.contains(worktree.id))
    await store.finish()
    #expect(watcherCommands.value == [.setOpenedWorktreeIDs([worktree.id])])
  }

  @Test(.dependencies) func tabClosedSyncsOpenedWorktreesToInfoWatcher() async {
    let worktree = makeWorktree()
    var repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: false,
      selected: true
    )
    repositoriesState.openedWorktreeIDs = [worktree.id]
    let watcherCommands = LockIsolated<[WorktreeInfoWatcherClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.worktreeInfoWatcher.send = { command in
        watcherCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.terminalEvent(.tabClosed(worktreeID: worktree.id, remainingTabs: 0)))
    await store.receive(\.repositories.markWorktreeClosed) {
      $0.repositories.openedWorktreeIDs = []
    }
    await store.finish()
    #expect(watcherCommands.value == [.setOpenedWorktreeIDs([])])
  }

  @Test(.dependencies) func tabRestoredSelectsTheRestoredWorktree() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: false,
      selected: false
    )
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.tabRestored(worktreeID: worktree.id, tabID: TerminalTabID())))
    await store.receive(\.repositories.selectWorktree)

    #expect(store.state.repositories.selection == .worktree(worktree.id))
    #expect(store.state.repositories.openedWorktreeIDs.contains(worktree.id))
  }

  @Test(.dependencies) func tabRestoredForUnknownWorktreeDoesNothing() async {
    let worktree = makeWorktree()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree, pendingSetupScript: false, selected: false),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.terminalEvent(.tabRestored(worktreeID: "/tmp/repo/missing", tabID: TerminalTabID())))
    await store.finish()
  }

  @Test(.dependencies) func tabRestoredIntoTheSelectedWorktreeSendsNothing() async {
    let worktree = makeWorktree()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree, pendingSetupScript: false, selected: true),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.terminalEvent(.tabRestored(worktreeID: worktree.id, tabID: TerminalTabID())))
    await store.finish()
  }

  @Test(.dependencies) func tabRestoredInCanvasRequestsTheCardFocus() async {
    let worktree = makeWorktree()
    var repositoriesState = makeRepositoriesState(worktree: worktree, pendingSetupScript: false, selected: false)
    repositoriesState.selection = .canvas
    let tabID = TerminalTabID()
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: SettingsFeature.State())
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.tabRestored(worktreeID: worktree.id, tabID: tabID)))
    await store.receive(\.repositories.newTerminalTabCreatedInCanvas)

    #expect(store.state.repositories.pendingCanvasFocusRequest?.target == .tab(tabID))
    #expect(store.state.repositories.selection == .canvas)
  }

  @Test(.dependencies) func setupScriptConsumedEventClearsPending() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: true,
      selected: true
    )
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.terminalEvent(.setupScriptConsumed(worktreeID: worktree.id)))
    await store.receive(\.repositories.worktreeCreation.consumeSetupScript) {
      $0.repositories.pendingSetupScriptWorktreeIDs.remove(worktree.id)
    }
    await store.finish()
  }

  @Test(.dependencies) func worktreeCreatedTriggersEnsureInitialTabWithSetupScriptFlag() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: true,
      selected: false
    )
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.repositories(.delegate(.worktreeCreated(worktree))))
    await store.finish()
    #expect(
      sent.value == [
        .ensureInitialTab(worktree, runSetupScriptIfNew: true, focusing: false)
      ]
    )
  }

  @Test(.dependencies) func worktreeCreatedSkipsSetupScriptFlagWhenNotPending() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: false,
      selected: false
    )
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.repositories(.delegate(.worktreeCreated(worktree))))
    await store.finish()
    #expect(
      sent.value == [
        .ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: false)
      ]
    )
  }

  private func makeWorktree() -> Worktree {
    Worktree(
      id: "/tmp/repo/wt-1",
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  // Round 3 review finding: plain folders in Canvas.
  @Test(.dependencies) func tabRestoredInCanvasRequestsTheCardFocusForAPlainFolder() async {
    let repository = Repository(
      id: "/tmp/plain-folder",
      rootURL: URL(fileURLWithPath: "/tmp/plain-folder"),
      name: "plain-folder",
      kind: .plain,
      worktrees: []
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .canvas
    let tabID = TerminalTabID()
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: SettingsFeature.State())
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.tabRestored(worktreeID: repository.id, tabID: tabID)))
    await store.receive(\.repositories.newTerminalTabCreatedInCanvas)

    #expect(store.state.repositories.pendingCanvasFocusRequest?.target == .tab(tabID))
  }

  private func makeRepositoriesState(
    worktree: Worktree,
    pendingSetupScript: Bool,
    selected: Bool
  ) -> RepositoriesFeature.State {
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: [worktree]
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    if selected {
      repositoriesState.selection = .worktree(worktree.id)
    }
    if pendingSetupScript {
      repositoriesState.pendingSetupScriptWorktreeIDs = [worktree.id]
    }
    return repositoriesState
  }
}
