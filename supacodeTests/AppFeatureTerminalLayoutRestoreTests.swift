import Clocks
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct AppFeatureTerminalLayoutRestoreTests {
  @Test(.dependencies) func repositoriesChangedRestoresLayoutOnceWhenEnabled() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.snapshotPersistencePhase = .active
    var settings = SettingsFeature.State()
    settings.restoreTerminalLayoutOnLaunch = true
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: settings)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.repositoriesChanged([repository])))) {
      $0.launchRestoreMode = .lastFocusedWorktree
      $0.isAwaitingLaunchLayoutRestore = true
      $0.repositories.selection = nil
    }
    await store.finish()

    #expect(
      sentCommands.value.contains(
        .restoreLayoutSnapshot(worktrees: [worktree])
      )
    )
  }

  @Test(.dependencies) func repositoriesChangedDuringRestoringPhaseDoesNotTriggerRestore() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.snapshotPersistencePhase = .restoring
    var settings = SettingsFeature.State()
    settings.restoreTerminalLayoutOnLaunch = true
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: settings)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    // repositoriesChanged can still arrive while phase is .restoring for states that are
    // not yet backed by a loaded repository snapshot. Layout restore must stay blocked there.
    await store.send(.repositories(.delegate(.repositoriesChanged([repository]))))
    await store.finish()

    #expect(
      sentCommands.value.contains {
        if case .restoreLayoutSnapshot = $0 {
          return true
        }
        return false
      } == false
    )
    // launchRestoreMode should remain .restoreLayout so the next repositoriesChanged
    // (after phase → .active) still has a chance to trigger the restore.
    #expect(store.state.launchRestoreMode == .restoreLayout)
  }

  @Test(.dependencies) func repositoriesChangedDuringRestoringPhaseTriggersFastPathAfterSnapshotLoad() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.snapshotPersistencePhase = .restoring
    repositoriesState.isInitialLoadComplete = true
    var settings = SettingsFeature.State()
    settings.restoreTerminalLayoutOnLaunch = true
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: settings)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.repositoriesChanged([repository])))) {
      $0.launchRestoreMode = .lastFocusedWorktree
      $0.isAwaitingLaunchLayoutRestore = true
      $0.repositories.selection = nil
    }
    await store.finish()

    #expect(
      sentCommands.value.contains(
        .restoreLayoutSnapshot(worktrees: [worktree])
      )
    )
  }

  @Test(.dependencies) func repositoriesChangedSkipsRestoreWhenDisabled() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.snapshotPersistencePhase = .active
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: SettingsFeature.State())
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.repositoriesChanged([repository]))))
    await store.finish()

    #expect(
      sentCommands.value.contains {
        if case .restoreLayoutSnapshot = $0 {
          return true
        }
        return false
      } == false
    )
  }

  @Test(.dependencies) func restoreOnlyTriggersOnce() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.snapshotPersistencePhase = .active
    var settings = SettingsFeature.State()
    settings.restoreTerminalLayoutOnLaunch = true
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: settings)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    // First repositoriesChanged triggers restore and flips mode
    await store.send(.repositories(.delegate(.repositoriesChanged([repository])))) {
      $0.launchRestoreMode = .lastFocusedWorktree
      $0.isAwaitingLaunchLayoutRestore = true
      $0.repositories.selection = nil
    }
    await store.finish()

    sentCommands.withValue { $0.removeAll() }

    // Second repositoriesChanged should NOT trigger restore
    await store.send(.repositories(.delegate(.repositoriesChanged([repository]))))
    await store.finish()

    #expect(
      sentCommands.value.contains {
        if case .restoreLayoutSnapshot = $0 {
          return true
        }
        return false
      } == false
    )
  }

  @Test(.dependencies) func repositoriesChangedSkipsLayoutRestoreForCliOpenMode() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.snapshotPersistencePhase = .active
    var appState = AppFeature.State(repositories: repositoriesState, settings: SettingsFeature.State())
    appState.launchRestoreMode = .cliOpenPath(worktree.workingDirectory.path(percentEncoded: false))
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])

    let store = TestStore(initialState: appState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.repositoriesChanged([repository]))))
    await store.finish()

    #expect(
      sentCommands.value.contains {
        if case .restoreLayoutSnapshot = $0 {
          return true
        }
        return false
      } == false
    )
  }

  @Test(.dependencies) func layoutRestoredEventSelectsWorktree() async {
    var initialState = AppFeature.State()
    initialState.isAwaitingLaunchLayoutRestore = true
    let store = TestStore(initialState: initialState) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestored(selectedWorktreeID: "/tmp/repo/wt-1"))) {
      $0.isAwaitingLaunchLayoutRestore = false
    }
    await store.receive(\.repositories.selectWorktree)
  }

  @Test(.dependencies) func layoutRestoredEventEnsuresInitialTabForSelectedWorktree() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = nil
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])

    let store = TestStore(
      initialState: {
        var state = AppFeature.State(repositories: repositoriesState)
        state.isAwaitingLaunchLayoutRestore = true
        return state
      }()
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestored(selectedWorktreeID: worktree.id))) {
      $0.isAwaitingLaunchLayoutRestore = false
    }
    await store.receive(\.repositories.selectWorktree) {
      $0.repositories.selection = .worktree(worktree.id)
      $0.repositories.openedWorktreeIDs = [worktree.id]
    }
    await store.receive(\.repositories.delegate.selectedWorktreeChanged)
    await store.finish()

    #expect(
      sentCommands.value.contains(
        .ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: false)
      )
    )
  }

  @Test(.dependencies) func layoutRestoredEventWakesAgentDetectionWhenPanelVisible() async {
    let suiteName = "AppFeatureTerminalLayoutRestoreTests.layoutRestoredEventWakesAgentDetectionWhenPanelVisible"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(false, forKey: "activeAgentsPanelHidden")
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = withDependencies {
      $0.defaultAppStorage = defaults
    } operation: {
      var initialState = AppFeature.State()
      initialState.isAwaitingLaunchLayoutRestore = true
      return TestStore(initialState: initialState) {
        AppFeature()
      } withDependencies: {
        $0.defaultAppStorage = defaults
        $0.terminalClient.send = { command in
          sentCommands.withValue { $0.append(command) }
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestored(selectedWorktreeID: nil))) {
      $0.isAwaitingLaunchLayoutRestore = false
    }
    await store.finish()

    #expect(sentCommands.value.contains(.setAgentDetectionEnabled(true)))
  }

  @Test(.dependencies) func layoutRestoredEventDisablesAgentDetectionWhenPanelHiddenAndAutoShowDisabled() async {
    let suiteName =
      "AppFeatureTerminalLayoutRestoreTests.layoutRestoredEventDisablesAgentDetectionWhenPanelHiddenAndAutoShowDisabled"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: "activeAgentsPanelHidden")
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = withDependencies {
      $0.defaultAppStorage = defaults
    } operation: {
      var initialState = AppFeature.State()
      initialState.isAwaitingLaunchLayoutRestore = true
      initialState.settings.autoShowActiveAgentsPanel = false
      return TestStore(initialState: initialState) {
        AppFeature()
      } withDependencies: {
        $0.defaultAppStorage = defaults
        $0.terminalClient.send = { command in
          sentCommands.withValue { $0.append(command) }
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestored(selectedWorktreeID: nil))) {
      $0.isAwaitingLaunchLayoutRestore = false
    }
    await store.finish()

    #expect(sentCommands.value.contains(.setAgentDetectionEnabled(false)))
  }

  @Test(.dependencies) func layoutRestoredEventWakesAgentDetectionWhenAutoShowEnabled() async {
    let suiteName = "AppFeatureTerminalLayoutRestoreTests.layoutRestoredEventWakesAgentDetectionWhenAutoShowEnabled"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: "activeAgentsPanelHidden")
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = withDependencies {
      $0.defaultAppStorage = defaults
    } operation: {
      var initialState = AppFeature.State()
      initialState.isAwaitingLaunchLayoutRestore = true
      initialState.settings.autoShowActiveAgentsPanel = true
      return TestStore(initialState: initialState) {
        AppFeature()
      } withDependencies: {
        $0.defaultAppStorage = defaults
        $0.terminalClient.send = { command in
          sentCommands.withValue { $0.append(command) }
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestored(selectedWorktreeID: nil))) {
      $0.isAwaitingLaunchLayoutRestore = false
    }
    await store.finish()

    #expect(sentCommands.value.contains(.setAgentDetectionEnabled(true)))
  }

  @Test(.dependencies) func layoutRestoredEventFallsBackToLastFocusedWorktreeWhenSelectedWorktreeMissing() async {
    let firstWorktree = Worktree(
      id: "/tmp/repo/wt-1",
      name: "wt-1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    let fallbackWorktree = Worktree(
      id: "/tmp/repo/wt-2",
      name: "wt-2",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-2"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    var repositoriesState = RepositoriesFeature.State(
      repositories: [makeRepository(worktrees: [firstWorktree, fallbackWorktree])]
    )
    repositoriesState.lastFocusedWorktreeID = fallbackWorktree.id
    let store = TestStore(
      initialState: {
        var state = AppFeature.State(repositories: repositoriesState)
        state.isAwaitingLaunchLayoutRestore = true
        return state
      }()
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestored(selectedWorktreeID: nil))) {
      $0.isAwaitingLaunchLayoutRestore = false
    }
    await store.receive(\.repositories.selectWorktree)
  }

  @Test(.dependencies) func layoutRestoredEventEnsuresInitialTabForFallbackWorktree() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.lastFocusedWorktreeID = worktree.id
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: {
        var state = AppFeature.State(repositories: repositoriesState)
        state.isAwaitingLaunchLayoutRestore = true
        return state
      }()
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestored(selectedWorktreeID: nil))) {
      $0.isAwaitingLaunchLayoutRestore = false
    }
    await store.receive(\.repositories.selectWorktree) {
      $0.repositories.selection = .worktree(worktree.id)
      $0.repositories.openedWorktreeIDs = [worktree.id]
    }
    await store.finish()

    #expect(
      sentCommands.value.contains(
        .ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: false)
      )
    )
  }

  @Test(.dependencies) func repositoriesLoadedEnsuresInitialTabForRestoredSelectionOnInitialLoad() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = .worktree(worktree.id)
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(
      .repositories(
        .repositoriesLoaded(
          [repository],
          failures: [],
          roots: [repository.rootURL],
          animated: false
        )
      )
    ) {
      $0.repositories.isInitialLoadComplete = true
      $0.repositories.snapshotPersistencePhase = .active
    }
    await store.receive(\.repositories.delegate.selectedWorktreeChanged)
    await store.finish()

    #expect(
      sentCommands.value.contains(
        .ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: false)
      )
    )
  }

  @Test(.dependencies) func repositoriesLoadedEnsuresInitialCanvasTabForRestoredCanvasOnInitialLoad() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = .canvas
    repositoriesState.preCanvasTerminalTargetID = worktree.id
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(
      .repositories(
        .repositoriesLoaded(
          [repository],
          failures: [],
          roots: [repository.rootURL],
          animated: false
        )
      )
    ) {
      $0.repositories.isInitialLoadComplete = true
      $0.repositories.snapshotPersistencePhase = .active
    }
    await store.finish()

    #expect(
      sentCommands.value.contains(
        .ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: false)
      )
    )
    #expect(sentCommands.value.contains(.setCanvasMode(true)))
  }

  @Test(.dependencies) func layoutRestoredEventReentersCanvasWhenPersisted() async {
    let suiteName = "AppFeatureTerminalLayoutRestoreTests.layoutRestoredEventReentersCanvasWhenPersisted"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: restoreCanvasModeOnLaunchAppStorageKey)

    let firstWorktree = Worktree(
      id: "/tmp/repo/wt-1",
      name: "wt-1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    let fallbackWorktree = Worktree(
      id: "/tmp/repo/wt-2",
      name: "wt-2",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-2"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    let repository = makeRepository(worktrees: [firstWorktree, fallbackWorktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.lastFocusedWorktreeID = fallbackWorktree.id
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
    ) {
      AppFeature()
    } withDependencies: {
      $0.defaultAppStorage = defaults
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestored(selectedWorktreeID: nil))) {
      $0.isAwaitingLaunchLayoutRestore = false
    }
    await store.receive(\.repositories.restoreCanvasOnLaunch) {
      $0.repositories.shouldCenterRestoredCanvasSoloTab = true
      $0.repositories.shouldFocusRestoredCanvasAtScaleOne = true
      $0.repositories.preCanvasWorktreeID = fallbackWorktree.id
      $0.repositories.preCanvasTerminalTargetID = fallbackWorktree.id
      $0.repositories.canvasReturnWorktreeID = fallbackWorktree.id
      $0.repositories.selection = .canvas
      $0.repositories.sidebarSelectedWorktreeIDs = []
    }
    await store.finish()

    #expect(
      sentCommands.value.contains(
        .ensureInitialTab(fallbackWorktree, runSetupScriptIfNew: false, focusing: false)
      )
    )
    #expect(sentCommands.value.contains(.setCanvasMode(true)))
  }

  @Test(.dependencies) func layoutRestoredEventSelectsRepositoryForPlainFolder() async {
    let plainRepo = makePlainRepository()
    let repositoriesState = RepositoriesFeature.State(repositories: [plainRepo])
    let store = TestStore(
      initialState: {
        var state = AppFeature.State(repositories: repositoriesState)
        state.isAwaitingLaunchLayoutRestore = true
        return state
      }()
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestored(selectedWorktreeID: plainRepo.id))) {
      $0.isAwaitingLaunchLayoutRestore = false
    }
    await store.receive(\.repositories.selectRepository)
  }

  @Test(.dependencies) func layoutRestoreFailedEventShowsWarningToast() async {
    var initialState = AppFeature.State()
    initialState.isAwaitingLaunchLayoutRestore = true
    let store = TestStore(initialState: initialState) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(.layoutRestoreFailed(message: "Saved terminal layout was invalid and has been reset"))
    ) {
      $0.isAwaitingLaunchLayoutRestore = false
    }
    await store.receive(\.repositories.showToast) {
      $0.repositories.statusToast = .warning("Saved terminal layout was invalid and has been reset")
    }
  }

  @Test(.dependencies) func repositoriesChangedAppliesDefaultShelfWhenNotRestoringLayout() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = .worktree(worktree.id)
    var settings = SettingsFeature.State()
    settings.defaultViewMode = .shelf

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: settings)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.repositoriesChanged([repository])))) {
      $0.hasAppliedInitialViewMode = true
    }
    await store.receive(\.repositories.toggleShelf) {
      $0.repositories.isShelfActive = true
      $0.repositories.openedWorktreeIDs = [worktree.id]
      $0.repositories.pendingTerminalFocusWorktreeIDs = [worktree.id]
    }
    await store.finish()
  }

  @Test(.dependencies) func repositoriesChangedAppliesDefaultCanvasWhenNotRestoringLayout() async {
    let clock = TestClock()
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = .worktree(worktree.id)
    var settings = SettingsFeature.State()
    settings.defaultViewMode = .canvas
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: settings)
    ) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.repositoriesChanged([repository])))) {
      $0.hasAppliedInitialViewMode = true
    }
    await store.receive(\.repositories.toggleCanvas)
    await store.receive(\.repositories.selectCanvas) {
      $0.repositories.preCanvasWorktreeID = worktree.id
      $0.repositories.preCanvasTerminalTargetID = worktree.id
      $0.repositories.selection = .canvas
    }
    await clock.advance(by: canvasSidebarAutoHideDelay)
    await store.finish()

    #expect(
      sentCommands.value.contains(
        .ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: false)
      )
    )
  }

  @Test(.dependencies) func layoutRestoredNilAppliesDefaultCanvasWithLastFocusedAnchor() async {
    let clock = TestClock()
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.lastFocusedWorktreeID = worktree.id
    repositoriesState.selection = nil
    var settings = SettingsFeature.State()
    settings.defaultViewMode = .canvas
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: settings)
    ) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestored(selectedWorktreeID: nil))) {
      $0.hasAppliedInitialViewMode = true
    }
    await store.receive(\.repositories.selectWorktree) {
      $0.repositories.selection = .worktree(worktree.id)
      $0.repositories.openedWorktreeIDs = [worktree.id]
    }
    await store.receive(\.repositories.toggleCanvas)
    await store.receive(\.repositories.selectCanvas) {
      $0.repositories.preCanvasWorktreeID = worktree.id
      $0.repositories.preCanvasTerminalTargetID = worktree.id
      $0.repositories.selection = .canvas
    }
    await clock.advance(by: canvasSidebarAutoHideDelay)
    await store.finish()

    #expect(
      sentCommands.value.contains(
        .ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: false)
      )
    )
  }

  @Test(.dependencies) func layoutRestoreFailedAppliesDefaultShelf() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.lastFocusedWorktreeID = worktree.id
    repositoriesState.selection = nil
    var settings = SettingsFeature.State()
    settings.defaultViewMode = .shelf

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: settings)
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestoreFailed(message: "Invalid layout"))) {
      $0.hasAppliedInitialViewMode = true
    }
    await store.receive(\.repositories.showToast) {
      $0.repositories.statusToast = .warning("Invalid layout")
    }
    await store.receive(\.repositories.toggleShelf) {
      $0.repositories.isShelfActive = true
    }
    await store.receive(\.repositories.selectWorktree) {
      $0.repositories.selection = .worktree(worktree.id)
      $0.repositories.openedWorktreeIDs = [worktree.id]
      $0.repositories.pendingTerminalFocusWorktreeIDs = [worktree.id]
    }
    await store.finish()
  }

  @Test(.dependencies) func scenePhaseInactiveSavesLayoutSnapshot() async {
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    var settings = SettingsFeature.State()
    settings.restoreTerminalLayoutOnLaunch = true
    let store = TestStore(initialState: AppFeature.State(settings: settings)) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.scenePhaseChanged(.inactive))
    await store.finish()

    #expect(sentCommands.value == [.saveLayoutSnapshot])
  }

  @Test(.dependencies) func scenePhaseInactiveSkipsSaveWhenRestoreDisabled() async {
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.scenePhaseChanged(.inactive))
    await store.finish()

    #expect(!sentCommands.value.contains(.saveLayoutSnapshot))
  }

  @Test(.dependencies) func clearLayoutSuppressesSaveOnScenePhaseInactive() async {
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    var settings = SettingsFeature.State()
    settings.restoreTerminalLayoutOnLaunch = true
    let store = TestStore(initialState: AppFeature.State(settings: settings)) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.terminalLayoutPersistence.clearSnapshot = { true }
    }
    store.exhaustivity = .off

    // Clear the layout
    await store.send(.settings(.delegate(.terminalLayoutSnapshotCleared(success: true)))) {
      $0.suppressLayoutSaveUntilRelaunch = true
    }
    await store.finish()

    sentCommands.withValue { $0.removeAll() }

    // Scene phase inactive should NOT save because layout was cleared
    await store.send(.scenePhaseChanged(.inactive))
    await store.finish()

    #expect(!sentCommands.value.contains(.saveLayoutSnapshot))
  }

  @Test(.dependencies) func suppressLayoutSavePersistsAcrossMultipleScenePhaseChanges() async {
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    var settings = SettingsFeature.State()
    settings.restoreTerminalLayoutOnLaunch = true
    let store = TestStore(initialState: AppFeature.State(settings: settings)) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.terminalLayoutPersistence.clearSnapshot = { true }
    }
    store.exhaustivity = .off

    // Clear the layout
    await store.send(.settings(.delegate(.terminalLayoutSnapshotCleared(success: true)))) {
      $0.suppressLayoutSaveUntilRelaunch = true
    }
    await store.finish()

    // Multiple inactive/active cycles should all skip saving
    for _ in 0..<3 {
      sentCommands.withValue { $0.removeAll() }
      await store.send(.scenePhaseChanged(.inactive))
      await store.finish()
      #expect(!sentCommands.value.contains(.saveLayoutSnapshot))
    }
  }
}

private func makeWorktree() -> Worktree {
  Worktree(
    id: "/tmp/repo/wt-1",
    name: "wt-1",
    detail: "",
    workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
    repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
  )
}

private func makeRepository(worktrees: [Worktree]) -> Repository {
  Repository(
    id: "/tmp/repo",
    rootURL: URL(fileURLWithPath: "/tmp/repo"),
    name: "repo",
    worktrees: IdentifiedArray(uniqueElements: worktrees)
  )
}

private func makePlainRepository() -> Repository {
  Repository(
    id: "/tmp/plain-folder",
    rootURL: URL(fileURLWithPath: "/tmp/plain-folder"),
    name: "plain-folder",
    kind: .plain,
    worktrees: IdentifiedArray()
  )
}
