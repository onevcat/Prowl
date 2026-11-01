import Clocks
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import ProwlCLIShared
import SwiftUI
import Testing

@testable import Prowl

// `repositoriesChanged` kicks off workflow history maintenance, which reads the
// date dependency. Isolate history per test so recovery cannot interrupt another test's runs.
@Suite(
  .dependency(\.continuousClock, ImmediateClock()),
  .dependency(\.date.now, Date(timeIntervalSince1970: 1_700_000_000)),
  .dependencies {
    $0[WorkflowHistoryStorageKey.self] = WorkflowHistoryStorage(
      baseURL: FileManager.default.temporaryDirectory.appending(path: "workflow-history-\(UUID().uuidString)"))
  }
)
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

    // repositoriesChanged arrives while phase is still .restoring (from snapshot load).
    // Layout restore must NOT trigger yet — only after phase becomes .active.
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

  @Test(.dependencies) func repositoriesChangedRestoresLayoutWhenSomeRepositoriesFailed() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.snapshotPersistencePhase = .withheld
    repositoriesState.loadFailuresByID = ["/tmp/missing": "boom"]
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
    var settings = SettingsFeature.State()
    settings.restoreTerminalLayoutOnLaunch = false
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
    appState.launchRestoreMode = .cliOpenPath(worktree.localURL!.path(percentEncoded: false))
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
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestored(selectedWorktreeID: "/tmp/repo/wt-1")))
    await store.receive(\.repositories.selectWorktree)
  }

  @Test(.dependencies) func layoutRestoredEventSelectsRepositoryForPlainFolder() async {
    let plainRepo = makePlainRepository()
    let repositoriesState = RepositoriesFeature.State(repositories: [plainRepo])
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestored(selectedWorktreeID: plainRepo.id)))
    await store.receive(\.repositories.selectRepository)
  }

  @Test(.dependencies) func layoutRestoreFailedEventShowsWarningToast() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(.layoutRestoreFailed(message: "Saved terminal layout was invalid and has been reset"))
    )
    await store.receive(\.repositories.showToast) {
      $0.repositories.statusToast = .warning("Saved terminal layout was invalid and has been reset")
    }
  }

  @Test(.dependencies) func repositoriesChangedAppliesDefaultShelfWhenNotRestoringLayout() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = .worktree(worktree.id)
    setDefaultViewMode(.shelf)
    defer { setDefaultViewMode(.normal) }
    var settings = SettingsFeature.State()
    settings.restoreTerminalLayoutOnLaunch = false

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
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = .worktree(worktree.id)
    setDefaultViewMode(.canvas)
    defer { setDefaultViewMode(.normal) }
    var settings = SettingsFeature.State()
    settings.restoreTerminalLayoutOnLaunch = false
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
      $0.hasAppliedInitialViewMode = true
    }
    await store.receive(\.repositories.enterCanvasAtLaunch)
    await store.receive(\.repositories.selectCanvas) {
      $0.repositories.preCanvasWorktreeID = worktree.id
      $0.repositories.preCanvasTerminalTargetID = worktree.id
      $0.repositories.selection = .canvas
    }
    await store.finish()

    #expect(
      sentCommands.value.contains(
        .ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: false)
      )
    )
  }

  @Test(.dependencies) func layoutRestoredNilAppliesDefaultCanvasWithLastFocusedAnchor() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.lastFocusedWorktreeID = worktree.id
    repositoriesState.selection = nil
    setDefaultViewMode(.canvas)
    defer { setDefaultViewMode(.normal) }
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
    ) {
      AppFeature()
    } withDependencies: {
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
    await store.receive(\.repositories.enterCanvasAtLaunch)
    await store.receive(\.repositories.selectCanvas) {
      $0.repositories.preCanvasWorktreeID = worktree.id
      $0.repositories.preCanvasTerminalTargetID = worktree.id
      $0.repositories.selection = .canvas
    }
    await store.finish()

    #expect(
      sentCommands.value.contains(
        .ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: false)
      )
    )
  }

  @Test(.dependencies) func layoutRestoredNilSelectsLastFocusedWorktree() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.lastFocusedWorktreeID = worktree.id
    repositoriesState.selection = nil
    setDefaultViewMode(.normal)

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestored(selectedWorktreeID: nil)))
    await store.receive(\.repositories.selectWorktree) {
      $0.repositories.selection = .worktree(worktree.id)
    }
  }

  @Test(.dependencies) func layoutRestoredNilSelectsAvailableWorktreeWhenLastFocusedIsGone() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.lastFocusedWorktreeID = "/tmp/removed/worktree"
    repositoriesState.selection = nil
    setDefaultViewMode(.normal)

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestored(selectedWorktreeID: nil)))
    await store.receive(\.repositories.selectWorktree) {
      $0.repositories.selection = .worktree(worktree.id)
    }
  }

  @Test(.dependencies) func layoutRestoreFailedSelectsLastFocusedWorktree() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.lastFocusedWorktreeID = worktree.id
    repositoriesState.selection = nil
    setDefaultViewMode(.normal)

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestoreFailed(message: "reset")))
    await store.receive(\.repositories.selectWorktree) {
      $0.repositories.selection = .worktree(worktree.id)
    }
  }

  @Test(.dependencies) func layoutRestoredNilSelectsPlainFolderWhenNoWorktreeIsAvailable() async {
    let plainRepository = makePlainRepository()
    var repositoriesState = RepositoriesFeature.State(repositories: [plainRepository])
    repositoriesState.lastFocusedWorktreeID = "/tmp/removed/worktree"
    repositoriesState.selection = nil
    setDefaultViewMode(.normal)

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestored(selectedWorktreeID: nil)))
    await store.receive(\.repositories.selectRepository)
  }

  @Test(.dependencies) func layoutRestoreFailedSelectsPlainFolderWhenNoWorktreeIsAvailable() async {
    let plainRepository = makePlainRepository()
    var repositoriesState = RepositoriesFeature.State(repositories: [plainRepository])
    repositoriesState.selection = nil
    setDefaultViewMode(.normal)

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestoreFailed(message: "reset")))
    await store.receive(\.repositories.selectRepository)
  }

  @Test(.dependencies) func layoutRestoredNilPrefersWorktreeOverPlainFolder() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [makePlainRepository(), repository])
    repositoriesState.selection = nil
    setDefaultViewMode(.normal)

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestored(selectedWorktreeID: nil)))
    await store.receive(\.repositories.selectWorktree) {
      $0.repositories.selection = .worktree(worktree.id)
    }
  }

  @Test(.dependencies) func layoutRestoredDefaultCanvasFocusesSelectedWorktree() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = nil
    setDefaultViewMode(.canvas)
    defer { setDefaultViewMode(.normal) }

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestored(selectedWorktreeID: worktree.id)))
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.repositories.selection == .canvas)
    let request = store.state.repositories.pendingCanvasFocusRequest
    #expect(request?.target == .selectedTabInWorktree(worktree.id))
    #expect(request?.viewport == .reveal)
  }

  @Test(.dependencies) func repositoriesChangedDefaultCanvasFocusesAnchorWithoutRestore() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = .worktree(worktree.id)
    setDefaultViewMode(.canvas)
    defer { setDefaultViewMode(.normal) }
    var settings = SettingsFeature.State()
    settings.restoreTerminalLayoutOnLaunch = false

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: settings)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.repositoriesChanged([repository]))))
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.repositories.pendingCanvasFocusRequest?.target == .selectedTabInWorktree(worktree.id))
  }

  @Test(.dependencies) func layoutRestoredDefaultCanvasEntersWithOnlyPlainFolder() async {
    let plainRepository = makePlainRepository()
    var repositoriesState = RepositoriesFeature.State(repositories: [plainRepository])
    repositoriesState.selection = nil
    setDefaultViewMode(.canvas)
    defer { setDefaultViewMode(.normal) }
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.layoutRestored(selectedWorktreeID: nil)))
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.repositories.selection == .canvas)
    #expect(store.state.repositories.pendingCanvasFocusRequest?.target == .selectedTabInWorktree(plainRepository.id))
    #expect(
      sentCommands.value.contains { command in
        if case .ensureInitialTab(let worktree, _, _) = command { return worktree.id == plainRepository.id }
        return false
      }
    )
  }

  @Test(.dependencies) func layoutRestoreFailedAppliesDefaultShelf() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.lastFocusedWorktreeID = worktree.id
    repositoriesState.selection = nil
    setDefaultViewMode(.shelf)
    defer { setDefaultViewMode(.normal) }

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
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

  @Test(.dependencies) func resigningActiveSavesLayoutSnapshotAfterRestoreConsumed() async {
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

    // Consume the restore mode via repositoriesChanged
    await store.send(.repositories(.delegate(.repositoriesChanged([repository])))) {
      $0.launchRestoreMode = .lastFocusedWorktree
      $0.repositories.selection = nil
    }
    await store.finish()
    sentCommands.withValue { $0.removeAll() }

    // Now resigning active should trigger save
    await store.send(.appActivityChanged(isActive: false))
    await store.finish()

    #expect(sentCommands.value == [.saveLayoutSnapshot])
  }

  @Test(.dependencies) func resigningActiveSkipsSaveDuringPendingRestore() async {
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

    // launchRestoreMode is .restoreLayout — save must be skipped
    // to prevent clearing a snapshot before restore has a chance to load it
    await store.send(.appActivityChanged(isActive: false))
    await store.finish()

    #expect(!sentCommands.value.contains(.saveLayoutSnapshot))
  }

  @Test(.dependencies) func resigningActiveSkipsSaveWhenRestoreDisabled() async {
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.appActivityChanged(isActive: false))
    await store.finish()

    #expect(!sentCommands.value.contains(.saveLayoutSnapshot))
  }

  @Test(.dependencies) func clearLayoutSuppressesSaveOnResigningActive() async {
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

    // Resigning active should NOT save because layout was cleared
    await store.send(.appActivityChanged(isActive: false))
    await store.finish()

    #expect(!sentCommands.value.contains(.saveLayoutSnapshot))
  }

  @Test(.dependencies) func suppressLayoutSavePersistsAcrossMultipleActivityChanges() async {
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

    // Multiple resign cycles should all skip saving
    for _ in 0..<3 {
      sentCommands.withValue { $0.removeAll() }
      await store.send(.appActivityChanged(isActive: false))
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

private func setDefaultViewMode(_ mode: DefaultViewMode) {
  @Shared(.settingsFile) var settingsFile
  $settingsFile.withLock {
    var updated = $0.global
    updated.defaultViewMode = mode
    $0.global = updated
  }
}
