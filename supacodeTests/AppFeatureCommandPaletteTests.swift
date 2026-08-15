import AppKit
import Clocks
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct AppFeatureCommandPaletteTests {
  @Test(.dependencies) func closingCommandPaletteRestoresSelectedTerminalFocus() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-focus/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-focus"
    )
    let repository = makeRepository(id: "/tmp/repo-focus", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    var state = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State()
    )
    state.commandPalette.isPresented = true
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.commandPalette(.setPresented(false))) {
      $0.commandPalette.isPresented = false
    }
    await store.finish()

    #expect(sent.value == [.focusSelectedTab(worktree)])
  }

  @Test(.dependencies) func togglingPresentedCommandPaletteClosedRestoresSelectedTerminalFocus()
    async
  {
    let worktree = makeWorktree(
      id: "/tmp/repo-toggle-focus/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-toggle-focus"
    )
    let repository = makeRepository(id: "/tmp/repo-toggle-focus", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    var state = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State()
    )
    state.commandPalette.isPresented = true
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.commandPalette(.togglePresented)) {
      $0.commandPalette.isPresented = false
    }
    await store.finish()

    #expect(sent.value == [.focusSelectedTab(worktree)])
  }

  @Test(.dependencies) func closingCommandPaletteDoesNotRestoreFocusWithoutSelectedTerminal() async
  {
    var state = AppFeature.State()
    state.commandPalette.isPresented = true
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.commandPalette(.setPresented(false))) {
      $0.commandPalette.isPresented = false
    }
    await store.finish()

    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func closingCommandPaletteInCanvasRestoresCanvasFocusedTerminalFocus() async
  {
    let worktree = makeWorktree(
      id: "/tmp/repo-canvas-focus/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-canvas-focus"
    )
    let repository = makeRepository(id: "/tmp/repo-canvas-focus", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .canvas
    var state = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State()
    )
    state.commandPalette.isPresented = true
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.canvasFocusedWorktreeID = { worktree.id }
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.commandPalette(.setPresented(false))) {
      $0.commandPalette.isPresented = false
    }
    await store.finish()

    #expect(sent.value == [.focusSelectedTab(worktree)])
  }

  @Test(.dependencies) func passiveCommandPaletteCommandInCanvasRestoresCanvasFocusedTerminalFocus()
    async
  {
    let worktree = makeWorktree(
      id: "/tmp/repo-canvas-passive/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-canvas-passive"
    )
    let repository = makeRepository(id: "/tmp/repo-canvas-passive", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .canvas
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.canvasFocusedWorktreeID = { worktree.id }
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.commandPalette(.delegate(.checkForUpdates)))
    await store.receive(\.updates.checkForUpdates)
    await store.finish()

    #expect(sent.value == [.focusSelectedTab(worktree)])
  }

  @Test(.dependencies) func passiveCommandPaletteCommandRestoresSelectedTerminalFocus() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-passive/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-passive"
    )
    let repository = makeRepository(id: "/tmp/repo-passive", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
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

    await store.send(.commandPalette(.delegate(.checkForUpdates)))
    await store.receive(\.updates.checkForUpdates)
    await store.finish()

    #expect(sent.value == [.focusSelectedTab(worktree)])
  }

  @Test(.dependencies) func selectingWorktreeDoesNotRestorePreviousTerminalFocus() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-select/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-select"
    )
    let repository = makeRepository(id: "/tmp/repo-select", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
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
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.selectWorktree(worktree.id))))
    await store.finish()

    #expect(!sent.value.contains(.focusSelectedTab(worktree)))
  }

  @Test(.dependencies) func openSettingsShowsWindow() async {
    let shown = LockIsolated(false)
    var state = AppFeature.State()
    state.settings.selection = .updates
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.settingsWindowClient.show = {
        shown.withValue { $0 = true }
      }
    }

    await store.send(.commandPalette(.delegate(.openSettings)))
    await store.receive(\.settings.setSelection) {
      $0.settings.selection = .general
    }
    await store.finish()
    #expect(shown.value)
  }

  @Test(.dependencies) func newWorktreeDispatchesCreateRandomWorktree() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Unable to create worktree")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Open a repository to create a worktree.")
    }

    await store.send(.commandPalette(.delegate(.newWorktree)))
    await store.receive(\.repositories.worktreeCreation.createRandomWorktree) {
      $0.repositories.alert = expectedAlert
    }
  }

  @Test(.dependencies) func openRepositoryShowsOpenPanel() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    await store.send(.commandPalette(.delegate(.openRepository)))
    await store.receive(\.repositories.setOpenPanelPresented) {
      $0.repositories.isOpenPanelPresented = true
    }
  }

  @Test(.dependencies) func revealInFinderOpensFocusedPaneDirectory() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-reveal-open/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-reveal-open"
    )
    let repository = makeRepository(id: "/tmp/repo-reveal-open", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let captured = LockIsolated<[(OpenWorktreeAction, Worktree)]>([])
    let requestedWorktreeIDs = LockIsolated<[Worktree.ID]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.focusedDirectoryPath = { worktreeID in
        requestedWorktreeIDs.withValue { $0.append(worktreeID) }
        return "/tmp/repo-reveal-open/wt-1/deep/nested"
      }
      $0.workspaceClient.open = { action, worktree, _ in
        captured.withValue { $0.append((action, worktree)) }
      }
    }

    await store.send(.commandPalette(.delegate(.revealInFinder)))
    await store.finish()

    #expect(requestedWorktreeIDs.value == [worktree.id])
    #expect(captured.value.count == 1)
    #expect(captured.value.first?.0 == .finder)
    #expect(
      captured.value.first?.1.workingDirectory.path(percentEncoded: false)
        == "/tmp/repo-reveal-open/wt-1/deep/nested"
    )
  }

  @Test(.dependencies) func revealInFinderFallsBackToWorktreeDirectoryWhenFocusedDirectoryMissing()
    async
  {
    let worktree = makeWorktree(
      id: "/tmp/repo-reveal-fallback/wt-2",
      name: "wt-2",
      repoRoot: "/tmp/repo-reveal-fallback"
    )
    let repository = makeRepository(id: "/tmp/repo-reveal-fallback", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let captured = LockIsolated<[(OpenWorktreeAction, Worktree)]>([])
    let requestedWorktreeIDs = LockIsolated<[Worktree.ID]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.focusedDirectoryPath = { worktreeID in
        requestedWorktreeIDs.withValue { $0.append(worktreeID) }
        return nil
      }
      $0.workspaceClient.open = { action, worktree, _ in
        captured.withValue { $0.append((action, worktree)) }
      }
    }

    await store.send(.commandPalette(.delegate(.revealInFinder)))
    await store.finish()

    #expect(requestedWorktreeIDs.value == [worktree.id])
    #expect(captured.value.count == 1)
    #expect(captured.value.first?.0 == .finder)
    #expect(
      captured.value.first?.1.workingDirectory.path(percentEncoded: false)
        == worktree.workingDirectory.path(percentEncoded: false)
    )
  }

  @Test(.dependencies) func openInVSCodeOpensFocusedDirectory() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-vscode-open/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-vscode-open"
    )
    let repository = makeRepository(id: "/tmp/repo-vscode-open", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let captured = LockIsolated<[(OpenWorktreeAction, Worktree)]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.focusedDirectoryPath = { _ in
        "/tmp/repo-vscode-open/wt-1/deep/nested"
      }
      $0.workspaceClient.open = { action, worktree, _ in
        captured.withValue { $0.append((action, worktree)) }
      }
    }

    await store.send(.commandPalette(.delegate(.openInVSCode)))
    await store.finish()

    #expect(captured.value.count == 1)
    #expect(captured.value.first?.0 == .vscode)
    #expect(
      captured.value.first?.1.workingDirectory.path(percentEncoded: false)
        == "/tmp/repo-vscode-open/wt-1/deep/nested"
    )
  }

  @Test(.dependencies) func openInForkOpensFocusedDirectory() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-fork-open/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-fork-open"
    )
    let repository = makeRepository(id: "/tmp/repo-fork-open", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let captured = LockIsolated<[(OpenWorktreeAction, Worktree)]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.focusedDirectoryPath = { _ in
        "/tmp/repo-fork-open/wt-1/deep/nested"
      }
      $0.workspaceClient.open = { action, worktree, _ in
        captured.withValue { $0.append((action, worktree)) }
      }
    }

    await store.send(.commandPalette(.delegate(.openInFork)))
    await store.finish()

    #expect(captured.value.count == 1)
    #expect(captured.value.first?.0 == .fork)
    #expect(
      captured.value.first?.1.workingDirectory.path(percentEncoded: false)
        == "/tmp/repo-fork-open/wt-1/deep/nested"
    )
  }

  @Test(.dependencies) func openWebOpensRepositoryURL() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-web-open/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-web-open"
    )
    let repository = makeRepository(id: "/tmp/repo-web-open", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let openedURLs = LockIsolated<[URL]>([])
    let requestedRoots = LockIsolated<[URL]>([])
    let repositoryURL = URL(string: "https://git.example.com:8443/scm/platform/repo")!
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.gitClient.repositoryWebURL = { rootURL in
        requestedRoots.withValue { $0.append(rootURL) }
        return repositoryURL
      }
      $0.openURLClient.open = { url in
        openedURLs.withValue { $0.append(url) }
      }
    }

    await store.send(.commandPalette(.delegate(.openWeb)))
    await store.finish()

    #expect(requestedRoots.value == [worktree.repositoryRootURL])
    #expect(openedURLs.value == [repositoryURL])
  }

  @Test(.dependencies) func openWebUsesCanvasFocusedWorktree() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-web-canvas/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-web-canvas"
    )
    let repository = makeRepository(id: "/tmp/repo-web-canvas", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .canvas
    let requestedRoots = LockIsolated<[URL]>([])
    let openedURLs = LockIsolated<[URL]>([])
    let repositoryURL = URL(string: "https://gitlab.internal.example.com/group/subgroup/repo")!
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.canvasFocusedWorktreeID = {
        worktree.id
      }
      $0.gitClient.repositoryWebURL = { rootURL in
        requestedRoots.withValue { $0.append(rootURL) }
        return repositoryURL
      }
      $0.openURLClient.open = { url in
        openedURLs.withValue { $0.append(url) }
      }
    }

    await store.send(.commandPalette(.delegate(.openWeb)))
    await store.finish()

    #expect(requestedRoots.value == [worktree.repositoryRootURL])
    #expect(openedURLs.value == [repositoryURL])
  }

  @Test(.dependencies) func openWebShowsAlertWhenRepositoryURLUnavailable() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-web-missing/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-web-missing"
    )
    let repository = makeRepository(id: "/tmp/repo-web-missing", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.gitClient.repositoryWebURL = { _ in nil }
    }

    await store.send(.commandPalette(.delegate(.openWeb)))
    await store.receive(\.repositoryWebURLUnavailable) {
      $0.alert = AlertState<AppFeature.Alert> {
        TextState("Repository URL not available")
      } actions: {
        ButtonState(role: .cancel, action: .dismiss) {
          TextState("OK")
        }
      } message: {
        TextState("Prowl could not determine a web URL for this repository.")
      }
    }
  }

  @Test(.dependencies) func openInForkUsesCanvasFocusedWorktree() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-fork-canvas/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-fork-canvas"
    )
    let repository = makeRepository(id: "/tmp/repo-fork-canvas", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .canvas
    let captured = LockIsolated<[(OpenWorktreeAction, Worktree)]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.canvasFocusedWorktreeID = {
        worktree.id
      }
      $0.workspaceClient.open = { action, worktree, _ in
        captured.withValue { $0.append((action, worktree)) }
      }
    }

    await store.send(.commandPalette(.delegate(.openInFork)))
    await store.finish()

    #expect(captured.value.count == 1)
    #expect(captured.value.first?.0 == .fork)
    #expect(captured.value.first?.1 == worktree)
  }

  @Test(.dependencies) func openInForkUsesFreestyleFocusedDirectory() async {
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.selection = .freestyle
    let captured = LockIsolated<[(OpenWorktreeAction, Worktree)]>([])
    let requestedWorktreeIDs = LockIsolated<[Worktree.ID]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.focusedDirectoryPath = { worktreeID in
        requestedWorktreeIDs.withValue { $0.append(worktreeID) }
        return "/tmp/freestyle/current"
      }
      $0.workspaceClient.open = { action, worktree, _ in
        captured.withValue { $0.append((action, worktree)) }
      }
    }

    await store.send(.commandPalette(.delegate(.openInFork)))
    await store.finish()

    #expect(requestedWorktreeIDs.value == [FreestyleTerminal.worktreeID])
    #expect(captured.value.count == 1)
    #expect(captured.value.first?.0 == .fork)
    #expect(
      captured.value.first?.1.workingDirectory.path(percentEncoded: false)
        == "/tmp/freestyle/current"
    )
  }

  @Test(.dependencies) func copyPathCopiesFocusedDirectory() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-copy-path/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-copy-path"
    )
    let repository = makeRepository(id: "/tmp/repo-copy-path", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let copiedPath = LockIsolated<String?>(nil)
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.focusedDirectoryPath = { _ in
        "/tmp/repo-copy-path/wt-1/current"
      }
      $0.clipboardClient.copyString = { value in
        copiedPath.setValue(value)
      }
    }

    await store.send(.commandPalette(.delegate(.copyPath)))
    await store.finish()

    #expect(copiedPath.value == "/tmp/repo-copy-path/wt-1/current")
  }

  @Test(.dependencies) func copyPathFallsBackToWorktreeRoot() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-copy-path-fallback/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-copy-path-fallback"
    )
    let repository = makeRepository(id: "/tmp/repo-copy-path-fallback", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let copiedPath = LockIsolated<String?>(nil)
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.focusedDirectoryPath = { _ in nil }
      $0.clipboardClient.copyString = { value in
        copiedPath.setValue(value)
      }
    }

    await store.send(.commandPalette(.delegate(.copyPath)))
    await store.finish()

    #expect(copiedPath.value == worktree.workingDirectory.path(percentEncoded: false))
  }

  @Test(.dependencies) func copyPathUsesCanvasFocusedWorktree() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-copy-path-canvas/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-copy-path-canvas"
    )
    let repository = makeRepository(id: "/tmp/repo-copy-path-canvas", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .canvas
    let copiedPath = LockIsolated<String?>(nil)
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.canvasFocusedWorktreeID = {
        worktree.id
      }
      $0.terminalClient.focusedDirectoryPath = { _ in
        "/tmp/repo-copy-path-canvas/wt-1/tab"
      }
      $0.clipboardClient.copyString = { value in
        copiedPath.setValue(value)
      }
    }

    await store.send(.commandPalette(.delegate(.copyPath)))
    await store.finish()

    #expect(copiedPath.value == "/tmp/repo-copy-path-canvas/wt-1/tab")
  }

  @Test(.dependencies) func layoutCenterQueuesCanvasLayoutCommand() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-layout-center/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-layout-center"
    )
    let repository = makeRepository(id: "/tmp/repo-layout-center", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .canvas
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.layoutCenter)))
    await store.receive(\.repositories.requestCanvasCommand) {
      $0.repositories.nextCanvasCommandRequestID = 1
      $0.repositories.pendingCanvasCommandRequest = CanvasCommandRequest(id: 1, command: .center)
    }

    #expect(store.state.repositories.pendingCanvasCommandRequest?.command == .center)
  }

  @Test(.dependencies) func layoutArrangeQueuesCanvasLayoutCommand() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-layout-arrange/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-layout-arrange"
    )
    let repository = makeRepository(id: "/tmp/repo-layout-arrange", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .canvas
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.layoutArrange)))
    await store.receive(\.repositories.requestCanvasCommand) {
      $0.repositories.nextCanvasCommandRequestID = 1
      $0.repositories.pendingCanvasCommandRequest = CanvasCommandRequest(id: 1, command: .arrange)
    }

    #expect(store.state.repositories.pendingCanvasCommandRequest?.command == .arrange)
  }

  @Test(.dependencies) func layoutOverviewQueuesCanvasLayoutCommand() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-layout-overview/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-layout-overview"
    )
    let repository = makeRepository(id: "/tmp/repo-layout-overview", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .canvas
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.layoutOverview)))
    await store.receive(\.repositories.requestCanvasCommand) {
      $0.repositories.nextCanvasCommandRequestID = 1
      $0.repositories.pendingCanvasCommandRequest = CanvasCommandRequest(id: 1, command: .overview)
    }

    #expect(store.state.repositories.pendingCanvasCommandRequest?.command == .overview)
  }

  @Test(.dependencies) func toggleCanvasZoomQueuesCanvasCommandOnlyInCanvas() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-layout-zoom/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-layout-zoom"
    )
    let repository = makeRepository(id: "/tmp/repo-layout-zoom", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .canvas
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.toggleCanvasZoom)
    await store.receive(\.repositories.requestCanvasCommand) {
      $0.repositories.nextCanvasCommandRequestID = 1
      $0.repositories.pendingCanvasCommandRequest = CanvasCommandRequest(
        id: 1, command: .toggleZoom)
    }

    #expect(store.state.repositories.pendingCanvasCommandRequest?.command == .toggleZoom)
  }

  @Test(.dependencies) func toggleCanvasZoomDoesNothingOutsideCanvas() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.toggleCanvasZoom)

    #expect(store.state.repositories.pendingCanvasCommandRequest == nil)
  }

  @Test(.dependencies) func refreshWorktreesDispatchesRefresh() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.refreshWorktrees)))
    await store.receive(\.repositories.refreshWorktrees)
  }

  @Test(.dependencies) func checkForUpdatesDispatchesUpdateAction() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    await store.send(.commandPalette(.delegate(.checkForUpdates)))
    await store.receive(\.updates.checkForUpdates)
  }

  @Test(.dependencies) func jumpToLatestUnreadDispatchesAppAction() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    await store.send(.commandPalette(.delegate(.jumpToLatestUnread)))
    await store.receive(\.jumpToLatestUnread)
  }

  @Test(.dependencies) func restoreRunningTabLoadsDetachedCardsIntoPalette() async {
    let candidate = TmuxDetachedCardCandidate(
      record: TmuxRawWindowRecord(
        sessionName: "prowl-cards",
        windowID: "@21",
        windowName: "shell",
        activePath: "/tmp/repo/wt",
        activeCommand: "zsh",
        activeTitle: "codex",
        managed: "1",
        cardID: "card-21",
        worktreeID: "/tmp/repo/wt",
        worktreePath: "/tmp/repo/wt",
        repositoryRoot: "/tmp/repo/",
        createdAt: "2026-05-28T12:00:00Z"
      )
    )!
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", name: "Repo", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.repositoryCustomTitles = [repository.id: "Custom Repo"]
    let store = TestStore(initialState: AppFeature.State(repositories: repositoriesState)) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.detachedTmuxCards = {
        TmuxCardRecoverySnapshot(candidates: [candidate], diagnostics: [])
      }
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.restoreRunningTab)))
    await store.receive(\.commandPalette.enterDetachedCardsMode)

    #expect(store.state.commandPalette.mode == .detachedCards)
    #expect(store.state.commandPalette.isPresented)
    #expect(
      store.state.commandPalette.detachedCards.rows == [
        TmuxDetachedCardPresentation(candidate: candidate, repositoryName: "Custom Repo")
      ])
    #expect(store.state.commandPalette.detachedCards.diagnostics.isEmpty)
    #expect(store.state.commandPalette.selectedIndex == 0)
  }

  @Test(.dependencies) func restoreDetachedCardDelegatesToTerminalClient() async {
    let restoredIDs = LockIsolated<[TmuxDetachedCardCandidate.ID]>([])
    let id = TmuxDetachedCardCandidate.ID(rawValue: "prowl.sock:@21")
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", name: "Repo", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    let store = TestStore(initialState: AppFeature.State(repositories: repositoriesState)) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.restoreDetachedTmuxCard = { candidateID, _ in
        restoredIDs.withValue { $0.append(candidateID) }
        return true
      }
    }

    await store.send(.commandPalette(.delegate(.restoreDetachedCard(id))))
    await store.finish()

    #expect(restoredIDs.value == [id])
  }

  @Test(.dependencies) func restoreDetachedCardsDelegatesEachSelectionToTerminalClient() async {
    let restoredIDs = LockIsolated<[TmuxDetachedCardCandidate.ID]>([])
    let first = TmuxDetachedCardCandidate.ID(rawValue: "prowl.sock:@21")
    let second = TmuxDetachedCardCandidate.ID(rawValue: "prowl.sock:@22")
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", name: "Repo", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    let store = TestStore(initialState: AppFeature.State(repositories: repositoriesState)) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.restoreDetachedTmuxCard = { candidateID, _ in
        restoredIDs.withValue { $0.append(candidateID) }
        return true
      }
    }

    await store.send(.commandPalette(.delegate(.restoreDetachedCards([first, second]))))
    await store.finish()

    #expect(restoredIDs.value == [first, second])
  }

  @Test(.dependencies) func selectWorktreeFromCommandPaletteInCanvasFocusesExistingCanvasCard()
    async
  {
    let worktree = makeWorktree(
      id: "/tmp/repo-canvas/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-canvas"
    )
    let repository = makeRepository(id: "/tmp/repo-canvas", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .canvas
    let focusedIDs = LockIsolated<[Worktree.ID]>([])
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State(),
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.focusWorktreeInCanvas = { worktreeID in
        focusedIDs.withValue { $0.append(worktreeID) }
        return true
      }
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.commandPalette(.delegate(.selectWorktree(worktree.id))))
    await store.finish()

    #expect(store.state.repositories.selection == .canvas)
    #expect(focusedIDs.value == [worktree.id])
    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies)
  func selectWorktreeFromCommandPaletteInCanvasCreatesTabWhenNoCanvasCardExists() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-canvas/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-canvas"
    )
    let repository = makeRepository(id: "/tmp/repo-canvas", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .canvas
    let focusedIDs = LockIsolated<[Worktree.ID]>([])
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State(),
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.focusWorktreeInCanvas = { worktreeID in
        focusedIDs.withValue { $0.append(worktreeID) }
        return false
      }
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.commandPalette(.delegate(.selectWorktree(worktree.id))))
    await store.receive(\.newTerminalFromCanvas)
    await store.finish()

    #expect(store.state.repositories.selection == .canvas)
    #expect(focusedIDs.value == [worktree.id])
    #expect(
      sent.value == [
        .createTabFromCanvas(worktree, runSetupScriptIfNew: false, inheritFromFocusedSurface: false)
      ],
    )
  }

  @Test(.dependencies) func ghosttyCommandDispatchesBindingActionToTerminalClient() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-ghostty/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-ghostty"
    )
    let repository = makeRepository(id: "/tmp/repo-ghostty", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
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

    await store.send(.commandPalette(.delegate(.ghosttyCommand("goto_split:right"))))
    await store.finish()

    // Two effects run in parallel (.merge) — assert both fire without
    // depending on dispatch order.
    #expect(sent.value.count == 2)
    #expect(sent.value.contains(.performBindingAction(worktree, action: "goto_split:right")))
    #expect(sent.value.contains(.focusSelectedTab(worktree)))
  }

  @Test(.dependencies) func viewToggleDelegateRestoresTerminalFocusByDefault() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-view-toggle/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-view-toggle"
    )
    let repository = makeRepository(id: "/tmp/repo-view-toggle", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
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
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.toggleLeftSidebar)))
    await store.finish()

    #expect(sent.value.contains(.focusSelectedTab(worktree)))
  }

  @Test(.dependencies) func toggleCanvasDelegateDoesNotRestoreTerminalFocus() async {
    let clock = TestClock()
    let worktree = makeWorktree(
      id: "/tmp/repo-canvas-toggle/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-canvas-toggle"
    )
    let repository = makeRepository(id: "/tmp/repo-canvas-toggle", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.toggleCanvas)))
    await store.finish()

    #expect(!sent.value.contains(.focusSelectedTab(worktree)))
  }

  @Test(.dependencies) func revealInFinderDispatchesOpenWorktreeFinder() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-finder/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-finder"
    )
    let repository = makeRepository(id: "/tmp/repo-finder", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let captured = LockIsolated<[(OpenWorktreeAction, Worktree)]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.workspaceClient.open = { action, worktree, _ in
        captured.withValue { $0.append((action, worktree)) }
      }
    }

    await store.send(.commandPalette(.delegate(.revealInFinder)))
    await store.finish()

    #expect(captured.value.count == 1)
    #expect(captured.value.first?.0 == .finder)
    #expect(captured.value.first?.1 == worktree)
  }

  @Test(.dependencies) func copyPathWritesWorktreePathToPasteboard() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-copy/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-copy"
    )
    let repository = makeRepository(id: "/tmp/repo-copy", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let copiedPath = LockIsolated<String?>(nil)
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.clipboardClient.copyString = { value in
        copiedPath.setValue(value)
      }
    }

    await store.send(.commandPalette(.delegate(.copyPath)))
    await store.finish()

    #expect(copiedPath.value == worktree.workingDirectory.path(percentEncoded: false))
  }

  @Test(.dependencies) func copyPathWithoutSelectedWorktreeIsNoop() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    await store.send(.commandPalette(.delegate(.copyPath)))
    await store.finish()
  }

  @Test(.dependencies) func revealInSidebarShowsSidebarAndReveals() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-reveal/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-reveal"
    )
    let repository = makeRepository(id: "/tmp/repo-reveal", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    var appState = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State()
    )
    appState.$isLeftSidebarHidden.withLock { $0 = true }
    let store = TestStore(initialState: appState) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.revealInSidebar)))
    await store.receive(\.showLeftSidebar) {
      $0.$isLeftSidebarHidden.withLock { $0 = false }
    }
    await store.receive(\.repositories.revealSelectedWorktreeInSidebar)
  }

  @Test(.dependencies) func revealInSidebarWithoutSelectedWorktreeIsNoop() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    await store.send(.commandPalette(.delegate(.revealInSidebar)))
    await store.finish()
  }

  @Test(.dependencies) func runScriptDelegateDispatchesAppAction() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.runScript)))
    await store.receive(\.runScript)
  }

  @Test(.dependencies) func stopRunScriptDelegateDispatchesAppAction() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.stopRunScript)))
    await store.receive(\.stopRunScript)
  }

  @Test(.dependencies) func togglePinWorktreeWhenNotPinnedDispatchesPin() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .commandPalette(.delegate(.togglePinWorktree("/tmp/repo/wt-1", isCurrentlyPinned: false)))
    )
    await store.receive(\.repositories.worktreeOrdering.pinWorktree)
  }

  @Test(.dependencies) func togglePinWorktreeWhenPinnedDispatchesUnpin() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .commandPalette(.delegate(.togglePinWorktree("/tmp/repo/wt-1", isCurrentlyPinned: true)))
    )
    await store.receive(\.repositories.worktreeOrdering.unpinWorktree)
  }

  @Test(.dependencies) func renameBranchDelegateDispatchesRequestPrompt() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-rename/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-rename"
    )
    let repository = makeRepository(id: "/tmp/repo-rename", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.renameBranch)))
    await store.receive(\.repositories.requestRenameBranchPrompt) {
      $0.repositories.nextPendingRenameBranchRequestID = 1
      $0.repositories.pendingRenameBranchRequest = PendingRenameBranchRequest(
        id: 1,
        worktreeID: worktree.id
      )
    }
  }

  @Test(.dependencies) func renameBranchDelegateNoopsWithoutSelectedWorktree() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    await store.send(.commandPalette(.delegate(.renameBranch)))
    await store.finish()
  }

  @Test(.dependencies) func openRepositorySettingsDelegateNavigatesAndShowsWindow() async {
    // Palette handler funnels through the existing
    // repositories.repositoryManagement.openRepositorySettings flow, which
    // guards on the repo actually existing.
    let repository = makeRepository(id: "/tmp/repo-x", worktrees: [])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    let shown = LockIsolated(false)
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.settingsWindowClient.show = { shown.withValue { $0 = true } }
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.openRepositorySettings("/tmp/repo-x"))))
    await store.receive(\.settings.setSelection) {
      $0.settings.selection = .repository("/tmp/repo-x")
    }
    await store.finish()
    #expect(shown.value)
  }

  @Test(.dependencies) func runCustomCommandDelegateDispatchesAppAction() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.runCustomCommand(3))))
    await store.receive(\.runCustomCommand)
  }

  @Test(.dependencies) func closePullRequestDispatchesAction() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.closePullRequest("/tmp/repo/wt-close"))))
    await store.receive(\.repositories.githubIntegration.pullRequestAction)
  }

  @Test(.dependencies) func deleteWorktreeDispatchesRequest() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-run/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-run"
    )
    let repository = makeRepository(id: "/tmp/repo-run", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.commandPalette(.delegate(.deleteWorktree(worktree.id, repository.id))))
    await store.receive(\.repositories.worktreeLifecycle.requestDeleteWorktree) {
      $0.repositories.deleteWorktreeConfirmation = DeleteWorktreeConfirmation(
        id: 0,
        title: "Delete worktree?",
        message: "Delete \(worktree.name)? The worktree directory will be removed.",
        targets: [
          RepositoriesFeature.DeleteWorktreeTarget(
            worktreeID: worktree.id, repositoryID: repository.id)
        ],
        deleteBranch: false
      )
      $0.repositories.nextDeleteWorktreeConfirmationID = 1
    }
  }

}

private func makeWorktree(id: String, name: String, repoRoot: String = "/tmp/repo") -> Worktree {
  Worktree(
    id: id,
    name: name,
    detail: "detail",
    workingDirectory: URL(fileURLWithPath: id),
    repositoryRootURL: URL(fileURLWithPath: repoRoot)
  )
}

private func makeRepository(id: String, name: String = "repo", worktrees: [Worktree]) -> Repository
{
  Repository(
    id: id,
    rootURL: URL(fileURLWithPath: id),
    name: name,
    worktrees: IdentifiedArray(uniqueElements: worktrees)
  )
}
