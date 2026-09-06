import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import ProwlCLIShared
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

  @Test(.dependencies) func togglingPresentedCommandPaletteClosedRestoresSelectedTerminalFocus() async {
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

  @Test(.dependencies) func closingCommandPaletteDoesNotRestoreFocusWithoutSelectedTerminal() async {
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

  @Test(.dependencies) func closingCommandPaletteInCanvasRestoresCanvasFocusedTerminalFocus() async {
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

  @Test(.dependencies) func passiveCommandPaletteCommandInCanvasRestoresCanvasFocusedTerminalFocus() async {
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

  @Test(.dependencies) func ghosttyCommandDelegateInCanvasUsesCanvasFocusedWorktree() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-canvas-ghostty/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-canvas-ghostty"
    )
    let repository = makeRepository(id: "/tmp/repo-canvas-ghostty", worktrees: [worktree])
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

    await store.send(.commandPalette(.delegate(.ghosttyCommand("new_tab"))))
    await store.finish()

    #expect(
      sent.value == [
        .performBindingAction(worktree, action: "new_tab"),
        .focusSelectedTab(worktree),
      ]
    )
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

  @Test(.dependencies) func selectingWorktreeInCanvasFocusesCanvasCard() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-select-canvas/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-select-canvas"
    )
    let repository = makeRepository(id: "/tmp/repo-select-canvas", worktrees: [worktree])
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
    }

    await store.send(.commandPalette(.delegate(.selectWorktree(worktree.id))))
    await store.receive(\.repositories.focusCanvasWorktree) {
      $0.repositories.nextCanvasFocusRequestID = 1
      $0.repositories.pendingCanvasFocusRequest = CanvasFocusRequest(
        id: 1,
        target: .worktree(worktree.id)
      )
      $0.repositories.openedWorktreeIDs = [worktree.id]
    }
  }

  @Test(.dependencies) func selectingPlainFolderInCanvasFocusesCanvasCard() async {
    let repository = Repository(
      id: "/tmp/folder-select-canvas",
      rootURL: URL(fileURLWithPath: "/tmp/folder-select-canvas"),
      name: "folder-select-canvas",
      kind: .plain,
      worktrees: []
    )
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
    }

    await store.send(.commandPalette(.delegate(.selectWorktree(repository.id))))
    await store.receive(\.repositories.focusCanvasRepository) {
      $0.repositories.nextCanvasFocusRequestID = 1
      $0.repositories.pendingCanvasFocusRequest = CanvasFocusRequest(
        id: 1,
        target: .worktree(repository.id)
      )
      $0.repositories.openedWorktreeIDs = [repository.id]
    }
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

  @Test(.dependencies) func newWorkspaceDispatchesPromptRequest() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    let title = "Workspace"
    let requestedRootPath = defaultWorkspaceBaseRootPath(for: title)
    let resolvedRootPath = expectedDefaultWorkspaceRootPath(for: title)
    await store.send(.commandPalette(.delegate(.newWorkspace)))
    await store.receive(\.repositories.workspaceCreation.promptRequested) {
      $0.repositories.workspaceCreationPrompt = WorkspaceCreationPromptFeature.State(
        repositories: [],
        title: title,
        rootPath: requestedRootPath
      )
    }
    if resolvedRootPath == requestedRootPath {
      await store.receive(\.repositories.workspaceCreation.defaultRootPathResolved)
    } else {
      await store.receive(\.repositories.workspaceCreation.defaultRootPathResolved) {
        $0.repositories.workspaceCreationPrompt?.rootPath = resolvedRootPath
      }
    }
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
    // depending on dispatch order. With no selected surface available the
    // dispatch falls back to the focused-surface command.
    #expect(sent.value.count == 2)
    #expect(sent.value.contains(.performBindingAction(worktree, action: "goto_split:right")))
    #expect(sent.value.contains(.focusSelectedTab(worktree)))
  }

  @Test(.dependencies) func ghosttyCommandTargetsSelectedSurfaceWhenAvailable() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-ghostty/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-ghostty"
    )
    let repository = makeRepository(id: "/tmp/repo-ghostty", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let surfaceID = UUID()
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
      $0.terminalClient.selectedSurfaceID = { _ in surfaceID }
    }

    await store.send(.commandPalette(.delegate(.ghosttyCommand("goto_split:right"))))
    await store.finish()

    #expect(sent.value.count == 2)
    #expect(
      sent.value.contains(
        .performBindingActionOnSurface(worktree, surfaceID: surfaceID, action: "goto_split:right")
      )
    )
    #expect(sent.value.contains(.focusSelectedTab(worktree)))
  }

  @Test(.dependencies) func ghosttyCommandCapturesSelectedSurfaceBeforeAsyncDispatch() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-ghostty/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-ghostty"
    )
    let repository = makeRepository(id: "/tmp/repo-ghostty", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let firstSurface = UUID()
    let secondSurface = UUID()
    let currentSurface = LockIsolated(firstSurface)
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
      $0.terminalClient.selectedSurfaceID = { _ in currentSurface.value }
    }

    let task = await store.send(.commandPalette(.delegate(.ghosttyCommand("toggle_split_zoom"))))
    // Simulates the palette-dismiss focus drift: by the time the async dispatch
    // resolves, `selectedSurfaceID` would already point at the leftmost surface.
    currentSurface.setValue(secondSurface)
    await task.finish()
    await store.finish()

    #expect(
      sent.value.contains(
        .performBindingActionOnSurface(worktree, surfaceID: firstSurface, action: "toggle_split_zoom")
      )
    )
    #expect(
      !sent.value.contains(
        .performBindingActionOnSurface(worktree, surfaceID: secondSurface, action: "toggle_split_zoom")
      )
    )
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
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.revealInFinder)))
    await store.receive(\.openWorktree)
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
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("__sentinel__", forType: .string)

    await store.send(.commandPalette(.delegate(.copyPath)))
    await store.finish()

    #expect(NSPasteboard.general.string(forType: .string) == worktree.workingDirectory.path)
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
    appState.leftSidebarVisibility = .detailOnly
    let store = TestStore(initialState: appState) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.revealInSidebar)))
    await store.receive(\.showLeftSidebar) {
      $0.leftSidebarVisibility = .all
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
        worktreeID: worktree.id,
        currentName: worktree.name
      )
    }
  }

  @Test(.dependencies) func renameBranchDelegateUsesCanvasFocusedWorktree() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-canvas-rename/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-canvas-rename"
    )
    let repository = makeRepository(id: "/tmp/repo-canvas-rename", worktrees: [worktree])
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
      $0.terminalClient.canvasFocusedWorktreeID = { worktree.id }
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.renameBranch)))
    await store.receive(\.repositories.requestRenameBranchPrompt) {
      $0.repositories.nextPendingRenameBranchRequestID = 1
      $0.repositories.pendingRenameBranchRequest = PendingRenameBranchRequest(
        id: 1,
        worktreeID: worktree.id,
        currentName: worktree.name
      )
    }
  }

  @Test(.dependencies) func renameBranchDelegateNoopsDuringSidebarMultiSelection() async {
    let worktreeA = makeWorktree(
      id: "/tmp/repo-multi-rename/wt-a",
      name: "wt-a",
      repoRoot: "/tmp/repo-multi-rename"
    )
    let worktreeB = makeWorktree(
      id: "/tmp/repo-multi-rename/wt-b",
      name: "wt-b",
      repoRoot: "/tmp/repo-multi-rename"
    )
    let repository = makeRepository(id: "/tmp/repo-multi-rename", worktrees: [worktreeA, worktreeB])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktreeA.id)
    repositoriesState.sidebarSelectedWorktreeIDs = [worktreeA.id, worktreeB.id]
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.commandPalette(.delegate(.renameBranch)))
    await store.finish()
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

    let commandID = EffectiveCustomCommand.Identifier(source: .global, commandID: "global-command")
    await store.send(.commandPalette(.delegate(.runCustomCommand(commandID))))
    await store.receive(\.runCustomCommand)
  }

  @Test(.dependencies) func showDiffDelegateUsesConfiguredExternalDiffTool() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-diff/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-diff"
    )
    let repository = makeRepository(id: "/tmp/repo-diff", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    var settings = GlobalSettings.default
    settings.externalDiffToolID = ExternalDiffTool.custom.settingsID
    settings.externalDiffCustomCommand = "my-diff {leftPath} {rightPath}"
    let storage = SettingsTestStorage()
    let settingsFileURL = URL(
      fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json"
    )
    let launched = LockIsolated<[(ExternalDiffSettings, DiffTarget)]>([])
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
      $0.terminalClient.send = { _ in }
      $0.externalDiffToolClient.open = { settings, target, _, _ in
        launched.withValue { $0.append((settings, target)) }
      }
    } operation: {
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global = settings }
      return TestStore(
        initialState: AppFeature.State(
          repositories: repositoriesState,
          settings: SettingsFeature.State(settings: settings)
        )
      ) {
        AppFeature()
      }
    }

    await store.send(.commandPalette(.delegate(.showDiff)))
    await store.finish()

    #expect(
      launched.value.map(\.0) == [
        ExternalDiffSettings(
          toolID: ExternalDiffTool.custom.settingsID,
          customCommand: "my-diff {leftPath} {rightPath}"
        )
      ]
    )
    #expect(launched.value.map(\.1) == [DiffTarget(worktree: worktree)])
  }

  @Test(.dependencies) func showSelectedWorktreeDiffUsesConfiguredExternalDiffTool() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-shortcut-diff/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-shortcut-diff"
    )
    let repository = makeRepository(id: "/tmp/repo-shortcut-diff", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    var settings = GlobalSettings.default
    settings.externalDiffToolID = ExternalDiffTool.custom.settingsID
    settings.externalDiffCustomCommand = "my-diff {leftPath} {rightPath}"
    let storage = SettingsTestStorage()
    let settingsFileURL = URL(
      fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json"
    )
    let launched = LockIsolated<[(ExternalDiffSettings, DiffTarget)]>([])
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
      $0.terminalClient.send = { _ in }
      $0.externalDiffToolClient.open = { settings, target, _, _ in
        launched.withValue { $0.append((settings, target)) }
      }
    } operation: {
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global = settings }
      return TestStore(
        initialState: AppFeature.State(
          repositories: repositoriesState,
          settings: SettingsFeature.State(settings: settings)
        )
      ) {
        AppFeature()
      }
    }

    await store.send(.showSelectedWorktreeDiff)
    await store.finish()

    #expect(
      launched.value.map(\.0) == [
        ExternalDiffSettings(
          toolID: ExternalDiffTool.custom.settingsID,
          customCommand: "my-diff {leftPath} {rightPath}"
        )
      ]
    )
    #expect(launched.value.map(\.1) == [DiffTarget(worktree: worktree)])
  }

  @Test(.dependencies) func showDiffForWorkspaceChildTargetsChildRepository() async {
    let entry = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      sourceKind: .existingPath
    )
    let workspace = Repository(
      id: "/tmp/ws-child-diff",
      rootURL: URL(fileURLWithPath: "/tmp/ws-child-diff"),
      name: "Workspace",
      kind: .plain,
      worktrees: [],
      workspace: ProjectWorkspace(title: "Workspace", repositories: [entry])
    )
    let childID = entry.resolvedURL(relativeTo: workspace.rootURL).path(percentEncoded: false)
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [workspace]
    repositoriesState.selection = .repository(workspace.id)
    repositoriesState.selectedWorkspaceChildID = childID
    repositoriesState.workspaceChildBranchByID[childID] = "feature/child"

    let launched = LockIsolated<[DiffTarget]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.externalDiffToolClient.open = { _, target, _, _ in
        launched.withValue { $0.append(target) }
      }
      // The effect canonicalizes the child's repository root at invocation
      // time; the resolved root must reach the diff client.
      $0.gitClient.repoRoot = { _ in URL(fileURLWithPath: "/tmp/child-source-root") }
    }
    store.exhaustivity = .off

    // Badge/context-menu route and selection-following shortcut route must
    // resolve to the same child target.
    await store.send(
      .repositories(.delegate(.showDiff(.workspaceChild(workspaceID: workspace.id, path: childID))))
    )
    await store.send(.showSelectedWorktreeDiff)
    await store.finish()

    let childURL = URL(fileURLWithPath: childID)
    #expect(launched.value.count == 2)
    for target in launched.value {
      #expect(target.id == .workspaceChild(workspaceID: workspace.id, path: childID))
      #expect(target.workingDirectory == childURL)
      #expect(target.branchName == "feature/child")
      #expect(target.repositoryRootURL == URL(fileURLWithPath: "/tmp/child-source-root"))
      #expect(target.terminalHost.id == workspace.id)
      #expect(target.terminalWorkingDirectory == childURL)
    }
  }

  @Test(.dependencies) func outgoingChangesForWorkspaceChildTargetsChildRepository() async {
    let entry = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      sourceKind: .existingPath
    )
    let workspace = Repository(
      id: "/tmp/ws-child-outgoing",
      rootURL: URL(fileURLWithPath: "/tmp/ws-child-outgoing"),
      name: "Workspace",
      kind: .plain,
      worktrees: [],
      workspace: ProjectWorkspace(title: "Workspace", repositories: [entry])
    )
    let childID = entry.resolvedURL(relativeTo: workspace.rootURL).path(percentEncoded: false)
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [workspace]
    repositoriesState.selection = .repository(workspace.id)
    repositoriesState.selectedWorkspaceChildID = childID

    let outgoingRequests = LockIsolated<[DiffTarget]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.outgoingChangesClient.open = { target, _, _ in
        outgoingRequests.withValue { $0.append(target) }
      }
      // A failed root canonicalization keeps the metadata fallback instead of
      // blocking the action.
      $0.gitClient.repoRoot = { _ in
        throw NSError(domain: "test", code: 1)
      }
    }
    store.exhaustivity = .off

    // Row context-menu delegate and selection-following shortcut/palette
    // route must both reach the outgoing client with the child target.
    await store.send(
      .repositories(
        .delegate(.showOutgoingChanges(.workspaceChild(workspaceID: workspace.id, path: childID)))
      )
    )
    await store.send(.showSelectedWorktreeOutgoingChanges)
    await store.finish()

    let childURL = URL(fileURLWithPath: childID)
    #expect(outgoingRequests.value.count == 2)
    for target in outgoingRequests.value {
      #expect(target.id == .workspaceChild(workspaceID: workspace.id, path: childID))
      #expect(target.workingDirectory == childURL)
      #expect(target.repositoryRootURL == childURL)
    }
  }

  @Test func commandPaletteOffersDiffItemsForSelectedWorkspaceChild() {
    let entry = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      sourceKind: .existingPath
    )
    let workspace = Repository(
      id: "/tmp/ws-palette-diff",
      rootURL: URL(fileURLWithPath: "/tmp/ws-palette-diff"),
      name: "Workspace",
      kind: .plain,
      worktrees: [],
      workspace: ProjectWorkspace(title: "Workspace", repositories: [entry])
    )
    let childID = entry.resolvedURL(relativeTo: workspace.rootURL).path(percentEncoded: false)
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [workspace]
    repositoriesState.selection = .repository(workspace.id)

    // Workspace selected without a child: no diff target, no diff items.
    let itemsWithoutChild = CommandPaletteFeature.commandPaletteItems(from: repositoriesState)
    #expect(!itemsWithoutChild.contains { $0.kind == .showDiff })
    #expect(!itemsWithoutChild.contains { $0.kind == .outgoingChanges })

    repositoriesState.selectedWorkspaceChildID = childID
    let items = CommandPaletteFeature.commandPaletteItems(from: repositoriesState)
    #expect(items.contains { $0.kind == .showDiff })
    #expect(items.contains { $0.kind == .outgoingChanges })
  }

  @Test(.dependencies) func outgoingChangesAlwaysUsesBuiltInClient() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-outgoing/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-outgoing"
    )
    let repository = makeRepository(id: "/tmp/repo-outgoing", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    repositoriesState.worktreeInfoByID[worktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: GithubPullRequest(
        number: 42,
        title: "Outgoing Changes",
        state: "OPEN",
        additions: 1,
        deletions: 0,
        isDraft: false,
        reviewDecision: nil,
        mergeable: nil,
        mergeStateStatus: nil,
        updatedAt: nil,
        url: "https://github.com/upstream/project/pull/42",
        headRefName: worktree.name,
        baseRefName: "main",
        commitsCount: 1,
        authorLogin: "onevcat",
        statusCheckRollup: nil
      )
    )
    #expect(
      CommandPaletteFeature.commandPaletteItems(from: repositoriesState).contains { $0.kind == .outgoingChanges }
    )
    let outgoingRequests = LockIsolated<[DiffTarget]>([])
    let externalRequests = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.outgoingChangesClient.open = { target, _, _ in
        outgoingRequests.withValue { $0.append(target) }
      }
      $0.externalDiffToolClient.open = { _, _, _, _ in
        externalRequests.withValue { $0 += 1 }
      }
    }

    await store.send(.commandPalette(.delegate(.showOutgoingChanges)))
    await store.send(.showSelectedWorktreeOutgoingChanges)
    await store.finish()

    let requests = outgoingRequests.value
    #expect(requests == [DiffTarget(worktree: worktree), DiffTarget(worktree: worktree)])
    #expect(externalRequests.value == 0)
  }

  @Test(.dependencies) func outgoingChangesWithoutPullRequestStillOpensViaClient() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-outgoing-no-pr/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-outgoing-no-pr"
    )
    let repository = makeRepository(id: "/tmp/repo-outgoing-no-pr", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let outgoingRequests = LockIsolated<[DiffTarget]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.outgoingChangesClient.open = { target, _, _ in
        outgoingRequests.withValue { $0.append(target) }
      }
    }

    await store.send(.showSelectedWorktreeOutgoingChanges)
    await store.finish()

    #expect(outgoingRequests.value == [DiffTarget(worktree: worktree)])
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func outgoingChangesResolutionFailureShowsAnAlert() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-outgoing-fail/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-outgoing-fail"
    )
    let repository = makeRepository(id: "/tmp/repo-outgoing-fail", worktrees: [worktree])
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
      $0.outgoingChangesClient.open = { _, _, onError in
        onError(
          OpenActionError(
            title: "Unable to show outgoing changes",
            message: OutgoingBaseResolutionError.noResolvableBase.localizedDescription
          )
        )
      }
    }
    store.exhaustivity = .off

    await store.send(.showSelectedWorktreeOutgoingChanges)
    await store.receive(\.openWorktreeFailed)

    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func sidebarOutgoingChangesDelegateTargetsTheRequestedWorktree() async {
    let selected = makeWorktree(
      id: "/tmp/repo-outgoing-target/wt-selected",
      name: "wt-selected",
      repoRoot: "/tmp/repo-outgoing-target"
    )
    let targeted = makeWorktree(
      id: "/tmp/repo-outgoing-target/wt-targeted",
      name: "wt-targeted",
      repoRoot: "/tmp/repo-outgoing-target"
    )
    let repository = makeRepository(id: "/tmp/repo-outgoing-target", worktrees: [selected, targeted])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(selected.id)
    let outgoingRequests = LockIsolated<[DiffTarget]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.outgoingChangesClient.open = { target, _, _ in
        outgoingRequests.withValue { $0.append(target) }
      }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.showOutgoingChanges(.worktree(targeted.id)))))
    await store.finish()

    #expect(outgoingRequests.value == [DiffTarget(worktree: targeted)])
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
        targets: [RepositoriesFeature.DeleteWorktreeTarget(worktreeID: worktree.id, repositoryID: repository.id)],
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

private func makeRepository(id: String, worktrees: [Worktree]) -> Repository {
  Repository(
    id: id,
    rootURL: URL(fileURLWithPath: id),
    name: "repo",
    worktrees: IdentifiedArray(uniqueElements: worktrees)
  )
}
