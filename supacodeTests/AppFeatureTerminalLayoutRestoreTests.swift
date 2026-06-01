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

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
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

    await store.send(.repositories(.delegate(.repositoriesChanged([repository])))) {
      $0.hasAppliedInitialViewMode = true
    }
    await store.receive(\.repositories.toggleCanvas)
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
    await store.receive(\.repositories.toggleCanvas)
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

private func setDefaultViewMode(_ mode: DefaultViewMode) {
  @Shared(.settingsFile) var settingsFile
  $settingsFile.withLock {
    var updated = $0.global
    updated.defaultViewMode = mode
    $0.global = updated
  }
}
