import ConcurrencyExtras
import DependenciesTestSupport
import Foundation
import GhosttyKit
import Testing

@testable import supacode

private final class MockTerminalInputSourceSelector: KeyboardInputSourceSelecting {
  var currentID = "com.example.inputmethod.Chinese"
  var selectedIDs: [String] = []

  func currentInputSourceID() -> String? {
    currentID
  }

  func selectInputSource(id: String) -> Bool {
    currentID = id
    selectedIDs.append(id)
    return true
  }

  func selectABC() -> Bool {
    selectInputSource(id: KeyboardInputSourceSelector.abcInputSourceID)
  }
}

@MainActor
struct WorktreeTerminalManagerTests {
  @Test func buffersEventsUntilStreamCreated() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.onSetupScriptConsumed?()

    let stream = manager.eventStream()
    let event = await nextEvent(stream) { event in
      if case .setupScriptConsumed = event {
        return true
      }
      return false
    }

    #expect(event == .setupScriptConsumed(worktreeID: worktree.id))
  }

  @Test func emitsEventsAfterStreamCreated() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let stream = manager.eventStream()
    let eventTask = Task {
      await nextEvent(stream) { event in
        if case .setupScriptConsumed = event {
          return true
        }
        return false
      }
    }

    state.onSetupScriptConsumed?()

    let event = await eventTask.value
    #expect(event == .setupScriptConsumed(worktreeID: worktree.id))
  }

  @Test func syncPreferredFontSizeNoOpForMissingState() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let stream = manager.eventStream()
    var iterator = stream.makeAsyncIterator()

    manager.syncPreferredFontSize(from: "/nonexistent")

    // Should not emit font event; only the notification indicator event
    let first = await iterator.next()
    #expect(first == .notificationIndicatorChanged(count: 0))
  }

  @Test func onFontSizeAdjustedCallbackIsWired() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    #expect(state.onFontSizeAdjusted != nil)
  }

  @Test func performFontSizeBindingActionRunsOnEveryExistingSurface() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktreeA = makeWorktree(id: "/tmp/repo/wt-a", name: "wt-a")
    let worktreeB = makeWorktree(id: "/tmp/repo/wt-b", name: "wt-b")
    let stateA = manager.state(for: worktreeA)
    let stateB = manager.state(for: worktreeB)
    let tabA1 = stateA.createTab()!
    let tabA2 = stateA.createTab()!
    let tabB = stateB.createTab()!
    let surfaces = [
      stateA.surfaceView(for: tabA1)!,
      stateA.surfaceView(for: tabA2)!,
      stateB.surfaceView(for: tabB)!,
    ]
    var actionsBySurfaceID: [UUID: [String]] = [:]
    for surface in surfaces {
      surface.onBindingActionForTesting = { action in
        actionsBySurfaceID[surface.id, default: []].append(action)
      }
    }

    let didPerform = manager.performFontSizeBindingAction("increase_font_size:1", from: worktreeA.id)

    #expect(didPerform == true)
    for surface in surfaces {
      #expect(actionsBySurfaceID[surface.id] == ["increase_font_size:1"])
    }
  }

  @Test func closeTargetAvailabilityFollowsTerminalModelState() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    #expect(state.canCloseFocusedTab == false)
    #expect(state.canCloseFocusedSurface == false)

    let tabId = state.createTab()

    #expect(tabId != nil)
    #expect(state.canCloseFocusedTab == true)
    #expect(state.canCloseFocusedSurface == true)

    if let tabId {
      state.closeTab(tabId)
    }

    #expect(state.canCloseFocusedTab == false)
    #expect(state.canCloseFocusedSurface == false)
  }

  @Test func firstTabUsesWindowSurfaceContext() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab())
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))
    let surface = try #require(state.surfaceView(for: surfaceId))

    #expect(surface.surfaceContextForTesting == GHOSTTY_SURFACE_CONTEXT_WINDOW)
  }

  @Test func splitTreeDoesNotRecreateSurfaceForClosedTab() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab())
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))

    state.closeTab(tabId)
    let staleTree = state.splitTree(for: tabId)

    #expect(staleTree.isEmpty)
    #expect(state.surfaceView(for: surfaceId) == nil)
    #expect(state.surfaceView(for: tabId) == nil)
  }

  @Test func ghosttyCloseRequestDoesNotRecreateSurfaceForClosedTab() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab())
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))
    let surface = try #require(state.surfaceView(for: surfaceId))

    surface.bridge.closeSurface(processAlive: false)
    let staleTree = state.splitTree(for: tabId)

    #expect(staleTree.isEmpty)
    #expect(state.tabManager.tabs.isEmpty)
    #expect(state.surfaceView(for: surfaceId) == nil)
    #expect(state.surfaceView(for: tabId) == nil)
  }

  @Test func focusWorktreeInCanvasForcesFocusChangeForAlreadyActiveSurface() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let tabID = state.createTab()

    #expect(tabID != nil)
    let initialFocusChange = manager.lastFocusChange

    let didFocus = manager.focusWorktreeInCanvas(worktreeID: worktree.id)

    #expect(didFocus)
    #expect(manager.canvasFocusedWorktreeID == worktree.id)
    #expect(manager.lastFocusChange != initialFocusChange)
  }

  @Test func creatingFocusedTabDefaultsInputSourceToABCBeforeProcessProbeCompletes() {
    let selector = MockTerminalInputSourceSelector()
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      inputSourceCoordinator: TerminalInputSourceCoordinator(selector: selector)
    )
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    manager.handleCommand(.setSelectedWorktreeID(worktree.id))

    _ = state.createTab()

    #expect(selector.selectedIDs == [KeyboardInputSourceSelector.abcInputSourceID])
  }

  @Test func worktreeStateReportsFocusedCommandSurfaceCreationSynchronously() {
    let state = WorktreeTerminalState(runtime: GhosttyRuntime(), worktree: makeWorktree())
    var createdSurfaceID: UUID?

    state.onFocusedCommandSurfaceCreated = { surfaceID in
      createdSurfaceID = surfaceID
    }

    let tabID = state.createTab()

    #expect(tabID != nil)
    #expect(createdSurfaceID == tabID.flatMap { state.focusedSurfaceId(in: $0) })
  }

  @Test func tmuxBackedTabUsesAttachCommand() async throws {
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        if arguments.contains("new-window") {
          return TmuxCommandResult(stdout: "@7 %9\n", stderr: "", exitCode: 0)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true
    )
    let worktree = makeWorktree()

    let tabID = try #require(await manager.createTabForTesting(in: worktree, runSetupScriptIfNew: false))
    let state = try #require(manager.stateIfExists(for: worktree.id))
    let surface = try #require(state.surfaceView(for: tabID))
    let launchCommand = try #require(surface.launchCommandForTesting)

    #expect(launchCommand.contains("-S"))
    #expect(launchCommand.contains("attach-session"))
    #expect(!launchCommand.contains("-CC"))
    #expect(state.tmuxTargetForTesting(tabID)?.windowID == TmuxWindowID(rawValue: "@7"))
    #expect(state.isTmuxBacked(tabID) == true)
  }

  @Test func detachedTmuxCardSnapshotFiltersVisibleManagerWindows() async throws {
    let separator = "\u{1F}"
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        if arguments.contains("new-window") {
          return TmuxCommandResult(stdout: "@22 %9\n", stderr: "", exitCode: 0)
        }
        if arguments.contains("list-sessions") {
          return TmuxCommandResult(
            stdout: ["prowl-cards", "2", "prowl-cards"].joined(separator: separator) + "\n",
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("list-windows") {
          return TmuxCommandResult(
            stdout: [
              [
                "prowl-cards", "@21", "detached", "/tmp/repo/wt", "zsh", "", "1", "card-21",
                "/tmp/repo/wt", "/tmp/repo/wt", "/tmp/repo", "2026-05-28T12:00:01Z",
              ].joined(separator: separator),
              [
                "prowl-cards", "@22", "visible", "/tmp/repo/wt", "zsh", "", "1", "card-22",
                "/tmp/repo/wt", "/tmp/repo/wt", "/tmp/repo", "2026-05-28T12:00:00Z",
              ].joined(separator: separator),
            ].joined(separator: "\n"),
            stderr: "",
            exitCode: 0
          )
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true
    )
    let worktree = makeWorktree()

    _ = try #require(await manager.createTabForTesting(in: worktree, runSetupScriptIfNew: false))
    let visibleWindowID = try #require(TmuxWindowID(rawValue: "@22"))

    #expect(manager.visibleTmuxWindowIDs() == Set([visibleWindowID]))
    let snapshot = await manager.detachedTmuxCardSnapshot()

    #expect(snapshot.candidates.map(\.windowID.rawValue) == ["@21"])
    #expect(snapshot.diagnostics.isEmpty)
  }

  @Test func detachedTmuxCardSnapshotFiltersAllAppManagedWindows() async throws {
    let separator = "\u{1F}"
    let outputs = TmuxNewWindowOutputQueue(["@1 %1\n", "@3 %3\n"])
    let worktreeA = makeWorktree(id: "/tmp/repo/wt-a", name: "wt-a")
    let worktreeB = makeWorktree(id: "/tmp/repo/wt-b", name: "wt-b")
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        if arguments.contains("new-window") {
          return TmuxCommandResult(stdout: await outputs.next(), stderr: "", exitCode: 0)
        }
        if arguments.contains("list-sessions") {
          return TmuxCommandResult(
            stdout: ["prowl-cards", "2", "prowl-cards"].joined(separator: separator) + "\n",
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("list-windows") {
          return TmuxCommandResult(
            stdout: [
              [
                "prowl-cards", "@1", "wt-a", "/tmp/repo/wt-a", "zsh", "", "1", "card-a",
                worktreeA.id, "/tmp/repo/wt-a", "/tmp/repo", "2026-05-28T12:00:01Z",
              ].joined(separator: separator),
              [
                "prowl-cards", "@3", "wt-b", "/tmp/repo/wt-b", "zsh", "", "1", "card-b",
                worktreeB.id, "/tmp/repo/wt-b", "/tmp/repo", "2026-05-28T12:00:00Z",
              ].joined(separator: separator),
            ].joined(separator: "\n"),
            stderr: "",
            exitCode: 0
          )
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true
    )

    _ = try #require(await manager.createTabForTesting(in: worktreeA, runSetupScriptIfNew: false))
    _ = try #require(await manager.createTabForTesting(in: worktreeB, runSetupScriptIfNew: false))
    manager.handleCommand(.setSelectedWorktreeID(worktreeA.id))

    #expect(manager.visibleTmuxWindowIDs().map(\.rawValue) == ["@1"])
    let snapshot = await manager.detachedTmuxCardSnapshot()

    #expect(snapshot.candidates.isEmpty)
  }

  @Test func detachedTmuxCardSnapshotOnlyShowsWindowsNotManagedByApp() async throws {
    let separator = "\u{1F}"
    let outputs = TmuxNewWindowOutputQueue(["@3 %3\n", "@7 %7\n", "@14 %14\n"])
    let tikTok = makeWorktree(id: "/tmp/repo/tiktok", name: "TikTok")
    let markEdit = makeWorktree(id: "/tmp/repo/markedit", name: "MarkEdit")
    let prowl = makeWorktree(id: "/tmp/repo/prowl", name: "Prowl")
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        if arguments.contains("new-window") {
          return TmuxCommandResult(stdout: await outputs.next(), stderr: "", exitCode: 0)
        }
        if arguments.contains("list-sessions") {
          return TmuxCommandResult(
            stdout: ["prowl-cards", "4", "prowl-cards"].joined(separator: separator) + "\n",
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("list-windows") {
          return TmuxCommandResult(
            stdout: [
              [
                "prowl-cards", "@17", "%17", "Freestyle", "/Users/yam", "zsh", "host", "1", "freestyle-card",
                "__freestyle__", "/Users/yam", "/Users/yam", "2026-05-29T16:00:33Z",
              ].joined(separator: separator),
              [
                "prowl-cards", "@7", "%7", "MarkEdit", "/tmp/repo/markedit", "zsh", "Commit Manager", "1",
                "markedit-card", markEdit.id, "/tmp/repo/markedit", "/tmp/repo", "2026-05-29T06:49:06Z",
              ].joined(separator: separator),
              [
                "prowl-cards", "@3", "%3", "TikTok", "/tmp/repo/tiktok", "zsh", "host", "1", "tiktok-card",
                tikTok.id, "/tmp/repo/tiktok", "/tmp/repo", "2026-05-29T05:33:58Z",
              ].joined(separator: separator),
              [
                "prowl-cards", "@14", "%14", "Prowl", "/tmp/repo/prowl", "zsh", "host", "1", "prowl-card",
                prowl.id, "/tmp/repo/prowl", "/tmp/repo", "2026-05-29T09:59:18Z",
              ].joined(separator: separator),
            ].joined(separator: "\n"),
            stderr: "",
            exitCode: 0
          )
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true
    )

    _ = try #require(await manager.createTabForTesting(in: tikTok, runSetupScriptIfNew: false))
    _ = try #require(await manager.createTabForTesting(in: markEdit, runSetupScriptIfNew: false))
    _ = try #require(await manager.createTabForTesting(in: prowl, runSetupScriptIfNew: false))
    manager.handleCommand(.setSelectedWorktreeID(prowl.id))

    #expect(manager.visibleTmuxWindowIDs().map(\.rawValue) == ["@14"])
    let snapshot = await manager.detachedTmuxCardSnapshot()

    #expect(snapshot.candidates.map(\.windowID.rawValue) == ["@17"])
  }

  @Test func restoresDetachedCardByAttachingExistingWindow() async throws {
    let separator = "\u{1F}"
    let recorder = TmuxCommandRecorder()
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        await recorder.record(arguments)
        if arguments.contains("list-sessions") {
          return TmuxCommandResult(
            stdout: ["prowl-cards", "1", "prowl-cards"].joined(separator: separator) + "\n",
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("list-windows") {
          return TmuxCommandResult(
            stdout: [
              "prowl-cards", "@21", "shell", "/tmp/repo/wt", "zsh", "codex", "1", "card-21",
              "/tmp/repo/wt", "/tmp/repo/wt", "/tmp/repo", "2026-05-28T12:00:00Z",
            ].joined(separator: separator),
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("display-message") {
          return TmuxCommandResult(stdout: "@21\n", stderr: "", exitCode: 0)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true
    )
    let worktree = makeWorktree(
      id: "/tmp/repo/wt",
      name: "wt",
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )

    let snapshot = await manager.detachedTmuxCardSnapshot()
    let candidateID = try #require(snapshot.candidates.first?.id)
    let restored = await manager.restoreDetachedTmuxCard(candidateID, worktrees: [worktree])

    let state = try #require(manager.stateIfExists(for: worktree.id))
    let restoredTab = try #require(state.tabManager.selectedTabId)
    let surface = try #require(state.surfaceView(for: restoredTab))
    let arguments = await recorder.arguments

    #expect(restored == true)
    #expect(manager.selectedWorktreeID == worktree.id)
    #expect(state.tmuxTargetForTesting(restoredTab)?.windowID?.rawValue == "@21")
    #expect(state.tmuxTargetForTesting(restoredTab)?.cardID.rawValue == "card-21")
    #expect(surface.launchCommandForTesting?.contains("attach-session") == true)
    #expect(surface.launchCommandForTesting?.contains("-CC") == false)
    #expect(arguments.contains { $0.contains("new-window") } == false)
  }

  @Test func plainTabReportsNotTmuxBacked() {
    let state = WorktreeTerminalState(runtime: GhosttyRuntime(), worktree: makeWorktree())

    let tabID = state.createTab()

    #expect(tabID.map { state.isTmuxBacked($0) } == false)
  }

  @Test func closingTmuxBackedTabDoesNotKillWindow() async throws {
    let separator = "\u{1F}"
    let recorder = TmuxCommandRecorder()
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        await recorder.record(arguments)
        if arguments.contains("new-window") {
          return TmuxCommandResult(stdout: "@22 %9\n", stderr: "", exitCode: 0)
        }
        if arguments.contains("list-sessions") {
          return TmuxCommandResult(
            stdout: ["prowl-cards", "1", "prowl-cards"].joined(separator: separator) + "\n",
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("list-windows") {
          return TmuxCommandResult(
            stdout: [
              "prowl-cards", "@22", "closed", "/tmp/repo/wt-1", "zsh", "", "1", "card-22",
              "/tmp/repo/wt-1", "/tmp/repo/wt-1", "/tmp/repo", "2026-05-28T12:00:00Z",
            ].joined(separator: separator),
            stderr: "",
            exitCode: 0
          )
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true
    )
    let worktree = makeWorktree()

    let tabID = try #require(await manager.createTabForTesting(in: worktree, runSetupScriptIfNew: false))
    let state = try #require(manager.stateIfExists(for: worktree.id))
    let windowID = try #require(TmuxWindowID(rawValue: "@22"))
    #expect(manager.visibleTmuxWindowIDs() == Set([windowID]))

    let argumentsBeforeClose = await recorder.arguments
    state.closeTab(tabID)
    await Task.yield()
    let snapshot = await manager.detachedTmuxCardSnapshot()

    let arguments = await recorder.arguments
    let closeArguments = Array(arguments.dropFirst(argumentsBeforeClose.count))
    #expect(closeArguments.contains { $0.contains("kill-window") } == false)
    #expect(closeArguments.contains { $0.contains("kill-session") })
    #expect(state.surfaceView(for: tabID) == nil)
    #expect(manager.visibleTmuxWindowIDs().contains(windowID) == false)
    #expect(snapshot.candidates.map(\.windowID.rawValue) == ["@22"])
  }

  @Test func closingLastTmuxBackedSurfaceClearsVisibleWindow() async throws {
    let recorder = TmuxCommandRecorder()
    let separator = "\u{1F}"
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        await recorder.record(arguments)
        if arguments.contains("new-window") {
          return TmuxCommandResult(stdout: "@22 %24\n", stderr: "", exitCode: 0)
        }
        if arguments.contains("list-sessions") {
          return TmuxCommandResult(
            stdout: [
              ["prowl-cards", "1", "prowl-cards"].joined(separator: separator),
              ["prowl-tab-222222222222", "1", ""].joined(separator: separator),
            ].joined(separator: "\n"),
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("list-windows") {
          return TmuxCommandResult(
            stdout: [
              "prowl-cards", "@22", "%24", "closed", "/tmp/repo/wt-1", "zsh", "", "1", "card-22",
              "/tmp/repo/wt-1", "/tmp/repo/wt-1", "/tmp/repo", "2026-05-28T12:00:00Z",
            ].joined(separator: separator),
            stderr: "",
            exitCode: 0
          )
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true
    )
    let worktree = makeWorktree()

    let tabID = try #require(await manager.createTabForTesting(in: worktree, runSetupScriptIfNew: false))
    let state = try #require(manager.stateIfExists(for: worktree.id))
    let surface = try #require(state.surfaceView(for: tabID))
    let windowID = try #require(TmuxWindowID(rawValue: "@22"))
    #expect(manager.visibleTmuxWindowIDs() == Set([windowID]))

    let argumentsBeforeClose = await recorder.arguments
    surface.bridge.closeSurface(processAlive: false)
    await Task.yield()
    let snapshot = await manager.detachedTmuxCardSnapshot()

    let arguments = await recorder.arguments
    let closeArguments = Array(arguments.dropFirst(argumentsBeforeClose.count))
    #expect(closeArguments.contains { $0.contains("kill-window") } == false)
    #expect(closeArguments.contains { $0.contains("kill-session") })
    #expect(state.surfaceView(for: tabID) == nil)
    #expect(manager.visibleTmuxWindowIDs().contains(windowID) == false)
    #expect(snapshot.candidates.map(\.windowID.rawValue) == ["@22"])
  }

  @Test func killingTmuxBackedTabKillsWindow() async throws {
    let recorder = TmuxCommandRecorder()
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        await recorder.record(arguments)
        if arguments.contains("new-window") {
          return TmuxCommandResult(stdout: "@7 %9\n", stderr: "", exitCode: 0)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true
    )
    let worktree = makeWorktree()

    let tabID = try #require(await manager.createTabForTesting(in: worktree, runSetupScriptIfNew: false))
    let didKill = await manager.killFocusedTab(in: worktree)

    let arguments = await recorder.arguments
    #expect(didKill == true)
    #expect(arguments.contains { $0.contains("kill-window") && $0.contains("@7") })
    let state = try #require(manager.stateIfExists(for: worktree.id))
    #expect(state.surfaceView(for: tabID) == nil)
  }

  @Test func existingTmuxBackedTabStillKillsWindowAfterTmuxCreationDisabled() async throws {
    let recorder = TmuxCommandRecorder()
    let creationEnabled = LockIsolated(true)
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        await recorder.record(arguments)
        if arguments.contains("new-window") {
          return TmuxCommandResult(stdout: "@7 %9\n", stderr: "", exitCode: 0)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmuxForWorktree: { _ in creationEnabled.value }
    )
    let worktree = makeWorktree()

    _ = try #require(await manager.createTabForTesting(in: worktree, runSetupScriptIfNew: false))
    creationEnabled.setValue(false)
    manager.handleCommand(.refreshAnonymousTmuxConfiguration(worktree))

    let didKill = await manager.killFocusedTab(in: worktree)
    let arguments = await recorder.arguments

    #expect(didKill == true)
    #expect(arguments.contains { $0.contains("kill-window") && $0.contains("@7") })
  }

  @Test func refreshAnonymousTmuxConfigurationUpdatesGhosttyNewTabImmediately() async throws {
    let creationEnabled = LockIsolated(true)
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        if arguments.contains("new-window") {
          return TmuxCommandResult(stdout: "@7 %9\n", stderr: "", exitCode: 0)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmuxForWorktree: { _ in creationEnabled.value }
    )
    let worktree = makeWorktree()
    let firstTabID = try #require(await manager.createTabForTesting(in: worktree, runSetupScriptIfNew: false))
    let state = try #require(manager.stateIfExists(for: worktree.id))
    let firstSurface = try #require(state.surfaceView(for: firstTabID))

    creationEnabled.setValue(false)
    manager.handleCommand(.refreshAnonymousTmuxConfiguration(worktree))
    #expect(firstSurface.bridge.onNewTab?() == true)

    let secondTabID = try #require(await waitForTabCount(2, in: state).last)
    let secondSurface = try #require(state.surfaceView(for: secondTabID))

    #expect(secondSurface.launchCommandForTesting == nil)
    #expect(state.tmuxTargetForTesting(secondTabID) == nil)
  }

  @Test func refreshAnonymousTmuxConfigurationUpdatesAppLevelNewTabImmediately() async throws {
    let creationEnabled = LockIsolated(true)
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        if arguments.contains("new-window") {
          return TmuxCommandResult(stdout: "@7 %9\n", stderr: "", exitCode: 0)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmuxForWorktree: { _ in creationEnabled.value }
    )
    let worktree = makeWorktree()

    _ = try #require(await manager.createTabForTesting(in: worktree, runSetupScriptIfNew: false))
    let state = try #require(manager.stateIfExists(for: worktree.id))

    creationEnabled.setValue(false)
    manager.handleCommand(.refreshAnonymousTmuxConfiguration(worktree))
    let secondTabID = try #require(await manager.createTabForTesting(in: worktree, runSetupScriptIfNew: false))
    let secondSurface = try #require(state.surfaceView(for: secondTabID))

    #expect(secondSurface.launchCommandForTesting == nil)
    #expect(state.tmuxTargetForTesting(secondTabID) == nil)
  }

  @Test func defaultManagerCreatesPlainSurfaceWithoutLaunchCommand() async throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()

    let tabID = try #require(await manager.createTabForTesting(in: worktree, runSetupScriptIfNew: false))
    let state = try #require(manager.stateIfExists(for: worktree.id))
    let surface = try #require(state.surfaceView(for: tabID))

    #expect(surface.launchCommandForTesting == nil)
  }

  @Test func perWorktreeAnonymousTmuxResolverControlsNewTabs() async throws {
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        if arguments.contains("new-window") {
          return TmuxCommandResult(stdout: "@7 %9\n", stderr: "", exitCode: 0)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let enabledRoot = URL(fileURLWithPath: "/tmp/repo-enabled")
    let disabledRoot = URL(fileURLWithPath: "/tmp/repo-disabled")
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmuxForWorktree: { worktree in
        worktree.repositoryRootURL == enabledRoot
      }
    )
    let enabledWorktree = makeWorktree(
      id: "/tmp/repo-enabled/wt-1",
      name: "enabled",
      repositoryRootURL: enabledRoot
    )
    let disabledWorktree = makeWorktree(
      id: "/tmp/repo-disabled/wt-1",
      name: "disabled",
      repositoryRootURL: disabledRoot
    )

    let enabledTabID = try #require(await manager.createTabForTesting(in: enabledWorktree, runSetupScriptIfNew: false))
    let disabledTabID = try #require(
      await manager.createTabForTesting(in: disabledWorktree, runSetupScriptIfNew: false))

    let enabledState = try #require(manager.stateIfExists(for: enabledWorktree.id))
    let disabledState = try #require(manager.stateIfExists(for: disabledWorktree.id))
    let enabledSurface = try #require(enabledState.surfaceView(for: enabledTabID))
    let disabledSurface = try #require(disabledState.surfaceView(for: disabledTabID))

    #expect(enabledSurface.launchCommandForTesting?.contains("attach-session") == true)
    #expect(enabledSurface.launchCommandForTesting?.contains("-CC") == false)
    #expect(disabledSurface.launchCommandForTesting == nil)
  }

  @Test func ghosttyNewTabActionUsesTmuxBackedCreationWhenEnabled() async throws {
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        if arguments.contains("new-window") {
          return TmuxCommandResult(stdout: "@7 %9\n", stderr: "", exitCode: 0)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true
    )
    let uniqueWorktreeID = "/tmp/repo/wt-\(UUID().uuidString)"
    let worktree = makeWorktree(id: uniqueWorktreeID, name: "wt")
    let firstTabID = try #require(await manager.createTabForTesting(in: worktree, runSetupScriptIfNew: false))
    let state = try #require(manager.stateIfExists(for: worktree.id))
    let firstSurface = try #require(state.surfaceView(for: firstTabID))

    #expect(firstSurface.bridge.onNewTab?() == true)

    let secondTabID = try #require(await waitForTmuxBackedTab(in: state, excluding: firstTabID))
    let secondSurface = try #require(state.surfaceView(for: secondTabID))

    #expect(secondSurface.launchCommandForTesting?.contains("attach-session") == true)
    #expect(secondSurface.launchCommandForTesting?.contains("-CC") == false)
    #expect(state.tmuxTargetForTesting(secondTabID)?.windowID == TmuxWindowID(rawValue: "@7"))
  }

  @Test func tmuxCreationDoesNotExposeTabBeforeAttachCommandReady() async throws {
    let gate = TmuxNewWindowGate()
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        await gate.record(arguments)
        if arguments.contains("new-window") {
          await gate.waitForRelease()
          return TmuxCommandResult(stdout: "@7 %9\n", stderr: "", exitCode: 0)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true
    )
    let worktree = makeWorktree()

    let createTask = Task {
      await manager.createTabForTesting(in: worktree, runSetupScriptIfNew: false)
    }
    let state = try await waitForState(worktree.id, in: manager)

    try await waitForTmuxNewWindowAttempt(gate)
    #expect(state.tabManager.tabs.isEmpty)

    await gate.release()

    let createdTabID = try #require(await createTask.value)
    let surface = try #require(state.surfaceView(for: createdTabID))

    #expect(state.tabManager.tabs.map(\.id) == [createdTabID])
    #expect(surface.launchCommandForTesting?.contains("attach-session") == true)
    #expect(surface.launchCommandForTesting?.contains("-CC") == false)
    #expect(state.tmuxTargetForTesting(createdTabID)?.windowID == TmuxWindowID(rawValue: "@7"))
  }

  @Test func tmuxCreationCancellationDoesNotCreateFallbackTab() async throws {
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        if arguments.contains("new-window") {
          throw CancellationError()
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true
    )
    let worktree = makeWorktree()

    let createdTabID = await manager.createTabForTesting(in: worktree, runSetupScriptIfNew: false)
    let state = try #require(manager.stateIfExists(for: worktree.id))

    #expect(createdTabID == nil)
    #expect(state.tabManager.tabs.isEmpty)
  }

  @Test func cancelledTmuxCreationCommandFailureDoesNotCreateFallbackTab() async throws {
    let gate = TmuxNewWindowGate()
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        await gate.record(arguments)
        if arguments.contains("new-window") {
          await gate.waitForRelease()
          return TmuxCommandResult(stdout: "", stderr: "cancelled", exitCode: 1)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true
    )
    let worktree = makeWorktree()

    let createTask = Task {
      await manager.createTabForTesting(in: worktree, runSetupScriptIfNew: false)
    }
    let state = try await waitForState(worktree.id, in: manager)

    try await waitForTmuxNewWindowAttempt(gate)
    #expect(state.tabManager.tabs.isEmpty)

    createTask.cancel()
    await gate.release()

    let createdTabID = await createTask.value

    #expect(createdTabID == nil)
    #expect(state.tabManager.tabs.isEmpty)
  }

  @Test func notificationIndicatorUsesCurrentCountOnStreamStart() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      WorktreeTerminalNotification(
        surfaceId: UUID(),
        title: "Unread",
        body: "body",
        isRead: false
      )
    ]
    state.onNotificationIndicatorChanged?()
    state.notifications = [
      WorktreeTerminalNotification(
        surfaceId: UUID(),
        title: "Read",
        body: "body",
        isRead: true
      )
    ]

    let stream = manager.eventStream()
    var iterator = stream.makeAsyncIterator()

    let first = await iterator.next()
    state.onSetupScriptConsumed?()
    let second = await iterator.next()

    #expect(first == .notificationIndicatorChanged(count: 0))
    #expect(second == .setupScriptConsumed(worktreeID: worktree.id))
  }

  @Test func taskStatusReflectsAnyRunningTab() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    #expect(manager.taskStatus(for: worktree.id) == .idle)

    let tab1 = TerminalTabID()
    let tab2 = TerminalTabID()
    state.tabIsRunningById[tab1] = false
    state.tabIsRunningById[tab2] = false
    #expect(manager.taskStatus(for: worktree.id) == .idle)

    state.tabIsRunningById[tab2] = true
    #expect(manager.taskStatus(for: worktree.id) == .running)

    state.tabIsRunningById[tab1] = true
    #expect(manager.taskStatus(for: worktree.id) == .running)

    state.tabIsRunningById[tab2] = false
    #expect(manager.taskStatus(for: worktree.id) == .running)

    state.tabIsRunningById[tab1] = false
    #expect(manager.taskStatus(for: worktree.id) == .idle)
  }

  @Test func hasUnseenNotificationsReflectsUnreadEntries() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      makeNotification(isRead: true),
      makeNotification(isRead: true),
    ]

    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)

    state.notifications.append(makeNotification(isRead: false))

    #expect(manager.hasUnseenNotifications(for: worktree.id) == true)
  }

  @Test func markAllNotificationsReadEmitsUpdatedIndicatorCount() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      makeNotification(isRead: false),
      makeNotification(isRead: true),
    ]

    let stream = manager.eventStream()
    var iterator = stream.makeAsyncIterator()

    let first = await iterator.next()
    state.markAllNotificationsRead()
    let second = await iterator.next()

    #expect(first == .notificationIndicatorChanged(count: 1))
    #expect(second == .notificationIndicatorChanged(count: 0))
    #expect(state.notifications.map(\.isRead) == [true, true])
  }

  @Test func markNotificationsReadOnlyAffectsMatchingSurface() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let surfaceA = UUID()
    let surfaceB = UUID()

    state.notifications = [
      makeNotification(surfaceId: surfaceA, isRead: false),
      makeNotification(surfaceId: surfaceB, isRead: false),
      makeNotification(surfaceId: surfaceB, isRead: true),
    ]

    state.markNotificationsRead(forSurfaceID: surfaceB)

    let aNotifications = state.notifications.filter { $0.surfaceId == surfaceA }
    let bNotifications = state.notifications.filter { $0.surfaceId == surfaceB }

    #expect(aNotifications.map(\.isRead) == [false])
    #expect(bNotifications.map(\.isRead) == [true, true])
    #expect(manager.hasUnseenNotifications(for: worktree.id) == true)

    state.markNotificationsRead(forSurfaceID: surfaceA)

    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)
  }

  @Test func markNotificationReadOnlyAffectsMatchingID() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let notificationA = UUID()
    let notificationB = UUID()
    let surfaceID = UUID()

    state.notifications = [
      makeNotification(id: notificationA, surfaceId: surfaceID, isRead: false),
      makeNotification(id: notificationB, surfaceId: surfaceID, isRead: false),
    ]

    state.markNotificationRead(id: notificationB)

    #expect(state.notifications.map(\.isRead) == [false, true])
    #expect(manager.hasUnseenNotifications(for: worktree.id) == true)
  }

  @Test func latestUnreadNotificationLocationChoosesNewestFocusableAcrossWorktrees() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktreeA = makeWorktree(id: "/tmp/repo/wt-a", name: "wt-a")
    let worktreeB = makeWorktree(id: "/tmp/repo/wt-b", name: "wt-b")
    let stateA = manager.state(for: worktreeA)
    let stateB = manager.state(for: worktreeB)
    let tabA = stateA.createTab()!
    let tabB = stateB.createTab()!
    let surfaceA = stateA.focusedSurfaceId(in: tabA)!
    let surfaceB = stateB.focusedSurfaceId(in: tabB)!
    let notificationA = UUID()
    let notificationB = UUID()

    stateA.notifications = [
      makeNotification(
        id: notificationA,
        surfaceId: surfaceA,
        createdAt: Date(timeIntervalSince1970: 10),
        isRead: false
      )
    ]
    stateB.notifications = [
      makeNotification(
        id: notificationB,
        surfaceId: surfaceB,
        createdAt: Date(timeIntervalSince1970: 20),
        isRead: false
      )
    ]

    #expect(
      manager.latestUnreadNotificationLocation()
        == NotificationLocation(
          worktreeID: worktreeB.id,
          tabID: tabB,
          surfaceID: surfaceB,
          notificationID: notificationB
        )
    )
  }

  @Test func latestUnreadNotificationLocationSkipsClosedSurfaces() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let tabID = state.createTab()!
    let surfaceID = state.focusedSurfaceId(in: tabID)!
    let focusableNotification = UUID()

    state.notifications = [
      makeNotification(
        surfaceId: UUID(),
        createdAt: Date(timeIntervalSince1970: 20),
        isRead: false
      ),
      makeNotification(
        id: focusableNotification,
        surfaceId: surfaceID,
        createdAt: Date(timeIntervalSince1970: 10),
        isRead: false
      ),
    ]

    #expect(
      manager.latestUnreadNotificationLocation()
        == NotificationLocation(
          worktreeID: worktree.id,
          tabID: tabID,
          surfaceID: surfaceID,
          notificationID: focusableNotification
        )
    )
  }

  @Test func setNotificationsDisabledMarksAllRead() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      makeNotification(isRead: false),
      makeNotification(isRead: false),
    ]

    state.setNotificationsEnabled(false)

    #expect(state.notifications.map(\.isRead) == [true, true])
    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)
  }

  @Test func dismissAllNotificationsClearsState() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      makeNotification(isRead: false),
      makeNotification(isRead: true),
    ]

    state.dismissAllNotifications()

    #expect(state.notifications.isEmpty)
    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)
  }

  @Test func makeLayoutSnapshotPersistsCustomTabTitle() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let tabID = try #require(state.createTab())

    state.tabManager.updateTitle(tabID, title: "npm test")
    state.tabManager.setCustomTitle(tabID, title: "Build")

    let snapshot = try #require(state.makeLayoutSnapshotWorktree())

    #expect(snapshot.tabs.first?.title == "npm test")
    #expect(snapshot.tabs.first?.customTitle == "Build")
  }

  @Test func tmuxBackedTabSnapshotRestoresAttachCommand() async throws {
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        if arguments.contains("new-window") {
          return TmuxCommandResult(stdout: "@7 %9\n", stderr: "", exitCode: 0)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let worktree = makeWorktree()
    let sourceManager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true
    )
    let sourceTabID = try #require(
      await sourceManager.createTabForTesting(in: worktree, runSetupScriptIfNew: false)
    )
    let sourceState = try #require(sourceManager.stateIfExists(for: worktree.id))

    let snapshot = try #require(sourceState.makeLayoutSnapshotWorktree())
    let snapshotTarget = try #require(snapshot.tabs.first?.tmuxTarget)
    let restoreManager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true
    )
    let restoreState = restoreManager.state(for: worktree)

    #expect(snapshotTarget.windowID == "@7")
    #expect(snapshotTarget.paneID == "%9")
    #expect(restoreState.applyLayoutSnapshot(snapshot))

    let restoredSurface = try #require(restoreState.surfaceView(for: sourceTabID))
    let restoredTarget = try #require(restoreState.tmuxTargetForTesting(sourceTabID))

    #expect(restoredSurface.launchCommandForTesting?.contains("attach-session") == true)
    #expect(restoredSurface.launchCommandForTesting?.contains("-CC") == false)
    #expect(restoredTarget.cardID.rawValue == sourceTabID.rawValue.uuidString)
    #expect(restoredTarget.windowID == TmuxWindowID(rawValue: "@7"))
    #expect(restoredTarget.paneID == TmuxPaneID(rawValue: "%9"))
  }

  @Test func tmuxBackedTabStripsClientSessionPrefixFromBridgeTitle() async throws {
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        if arguments.contains("new-window") {
          return TmuxCommandResult(stdout: "@7 %9\n", stderr: "", exitCode: 0)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true
    )
    let worktree = makeWorktree(name: "master")

    let tabID = try #require(await manager.createTabForTesting(in: worktree, runSetupScriptIfNew: false))
    let state = try #require(manager.stateIfExists(for: worktree.id))
    let target = try #require(state.tmuxTargetForTesting(tabID))
    let surface = try #require(state.surfaceView(for: tabID))

    surface.bridge.onTitleChange?("\(target.clientSession):2.1 master 1")
    surface.bridge.onTitleChange?("\(target.clientSession):2.1 master 1")

    let displayTitle = state.tabManager.tabs.first(where: { $0.id == tabID })?.displayTitle

    #expect(displayTitle == "master")
  }

  @Test func tmuxSnapshotRestoresPlainTabWithSplitRoot() throws {
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, _ in TmuxCommandResult(stdout: "", stderr: "", exitCode: 0) }
    )
    let tabID = UUID()
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true
    )
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let snapshot = TerminalLayoutSnapshotPayload.SnapshotWorktree(
      worktreeID: worktree.id,
      selectedTabID: tabID.uuidString,
      tabs: [
        TerminalLayoutSnapshotPayload.SnapshotTab(
          tabID: tabID.uuidString,
          title: nil,
          icon: nil,
          splitRoot: .split(
            direction: .horizontal,
            ratio: 0.5,
            children: [
              .leaf(surfaceID: UUID().uuidString),
              .leaf(surfaceID: UUID().uuidString),
            ]
          ),
          tmuxTarget: TerminalLayoutSnapshotPayload.SnapshotTmuxTarget(
            socketPath: "/tmp/prowl/tmux/prowl.sock",
            groupSession: "prowl-wt-abc123",
            clientSession: "prowl-tab-def456",
            windowID: "@7",
            paneID: "%9"
          )
        )
      ]
    )
    let terminalTabID = TerminalTabID(rawValue: tabID)

    #expect(state.applyLayoutSnapshot(snapshot))

    let restoredSurface = try #require(state.surfaceView(for: terminalTabID))
    #expect(restoredSurface.launchCommandForTesting == nil)
    #expect(state.tmuxTargetForTesting(terminalTabID) == nil)
  }

  @Test func tmuxSnapshotRestoresPlainTabWithUnavailableController() throws {
    let tabID = UUID()
    let controller = TmuxTerminalController(resolveExecutable: { nil })
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true
    )
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let snapshot = TerminalLayoutSnapshotPayload.SnapshotWorktree(
      worktreeID: worktree.id,
      selectedTabID: tabID.uuidString,
      tabs: [
        TerminalLayoutSnapshotPayload.SnapshotTab(
          tabID: tabID.uuidString,
          title: nil,
          icon: nil,
          splitRoot: .leaf(surfaceID: UUID().uuidString),
          tmuxTarget: TerminalLayoutSnapshotPayload.SnapshotTmuxTarget(
            socketPath: "/tmp/prowl/tmux/prowl.sock",
            groupSession: "prowl-wt-abc123",
            clientSession: "prowl-tab-def456",
            windowID: "@7",
            paneID: "%9"
          )
        )
      ]
    )
    let terminalTabID = TerminalTabID(rawValue: tabID)

    #expect(state.applyLayoutSnapshot(snapshot))

    let restoredSurface = try #require(state.surfaceView(for: terminalTabID))
    #expect(restoredSurface.launchCommandForTesting == nil)
    #expect(state.tmuxTargetForTesting(terminalTabID) == nil)
  }

  @Test func applyLayoutSnapshotRestoresCustomTabTitle() throws {
    let tabID = UUID()
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let snapshot = TerminalLayoutSnapshotPayload.SnapshotWorktree(
      worktreeID: worktree.id,
      selectedTabID: tabID.uuidString,
      tabs: [
        TerminalLayoutSnapshotPayload.SnapshotTab(
          tabID: tabID.uuidString,
          title: "npm test",
          customTitle: "Build",
          icon: nil,
          splitRoot: .leaf(surfaceID: UUID().uuidString)
        )
      ]
    )

    #expect(state.applyLayoutSnapshot(snapshot))
    let restored = try #require(state.tabManager.tabs.first)

    #expect(restored.title == "npm test")
    #expect(restored.customTitle == "Build")
    #expect(restored.displayTitle == "Build")
    #expect(restored.isTitleLocked == false)
  }

  @Test func applyLayoutSnapshotWakesAgentDetectionForRestoredSurface() throws {
    let tabID = UUID()
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let snapshot = TerminalLayoutSnapshotPayload.SnapshotWorktree(
      worktreeID: worktree.id,
      selectedTabID: tabID.uuidString,
      tabs: [
        TerminalLayoutSnapshotPayload.SnapshotTab(
          tabID: tabID.uuidString,
          title: nil,
          icon: nil,
          splitRoot: .leaf(surfaceID: UUID().uuidString)
        )
      ]
    )
    let terminalTabID = TerminalTabID(rawValue: tabID)

    #expect(state.applyLayoutSnapshot(snapshot))
    let restoredSurface = try #require(state.surfaceView(for: terminalTabID))

    #expect(state.agentDetectionSchedules[restoredSurface.id] != nil)
    #expect(state.surfaceAgentStates[restoredSurface.id] != nil)
    state.setAgentDetectionEnabled(false)
  }

  @Test func setAgentDetectionEnabledWakesSurfacesWhenAlreadyEnabled() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let tabID = try #require(state.createTab())
    let surface = try #require(state.surfaceView(for: tabID))

    #expect(state.agentDetectionEnabled == true)
    #expect(state.agentDetectionSchedules[surface.id] == nil)

    state.setAgentDetectionEnabled(true)

    #expect(state.agentDetectionSchedules[surface.id] != nil)
    #expect(state.surfaceAgentStates[surface.id] != nil)
    state.setAgentDetectionEnabled(false)
  }

  @Test func managerSetAgentDetectionEnabledWakesStatesWhenAlreadyEnabled() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let tabID = try #require(state.createTab())
    let surface = try #require(state.surfaceView(for: tabID))

    #expect(state.agentDetectionEnabled == true)
    #expect(state.agentDetectionSchedules[surface.id] == nil)

    manager.setAgentDetectionEnabled(true)

    #expect(state.agentDetectionSchedules[surface.id] != nil)
    #expect(state.surfaceAgentStates[surface.id] != nil)
    state.setAgentDetectionEnabled(false)
  }

  @Test func restoreLayoutSnapshotFailClosedClearsSnapshotWhenWorktreeMissing() async {
    let clearCount = LockIsolated(0)
    let snapshot = TerminalLayoutSnapshotPayload(
      worktrees: [
        TerminalLayoutSnapshotPayload.SnapshotWorktree(
          worktreeID: "/tmp/repo/wt-1",
          selectedTabID: "F96839F5-1371-4841-9E41-49124D918A67",
          tabs: [
            TerminalLayoutSnapshotPayload.SnapshotTab(
              tabID: "F96839F5-1371-4841-9E41-49124D918A67",
              title: nil,
              icon: nil,
              splitRoot: .leaf(surfaceID: "9B2F6D8C-44A4-42C5-8F9E-962108301901")
            )
          ]
        )
      ]
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      layoutPersistence: TerminalLayoutPersistenceClient(
        loadSnapshot: { snapshot },
        saveSnapshot: { _ in true },
        clearSnapshot: {
          clearCount.withValue { $0 += 1 }
          return true
        }
      )
    )
    let stream = manager.eventStream()

    await manager.restoreLayoutSnapshot(from: [])

    let event = await nextEvent(stream) { event in
      if case .layoutRestoreFailed = event {
        return true
      }
      return false
    }

    #expect(clearCount.value == 1)
    #expect(event == .layoutRestoreFailed(message: "Saved terminal layout was invalid and has been reset"))
  }

  @Test func restoreLayoutSnapshotWithoutSnapshotEmitsEmptyRestoreEvent() async {
    let clearCount = LockIsolated(0)
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      layoutPersistence: TerminalLayoutPersistenceClient(
        loadSnapshot: { nil },
        saveSnapshot: { _ in true },
        clearSnapshot: {
          clearCount.withValue { $0 += 1 }
          return true
        }
      )
    )
    let stream = manager.eventStream()

    await manager.restoreLayoutSnapshot(from: [makeWorktree()])

    let event = await nextEvent(stream) { event in
      event == .layoutRestored(selectedWorktreeID: nil)
    }

    #expect(clearCount.value == 0)
    #expect(event == .layoutRestored(selectedWorktreeID: nil))
  }

  @Test func restoreLayoutSnapshotWithoutSnapshotRestoresDetachedTmuxCards() async throws {
    let separator = "\u{1F}"
    let worktree = makeWorktree(
      id: "/tmp/repo/wt",
      name: "wt",
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        if arguments.contains("list-sessions") {
          return TmuxCommandResult(
            stdout: ["prowl-cards", "1", "prowl-cards"].joined(separator: separator) + "\n",
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("list-windows") {
          return TmuxCommandResult(
            stdout: [
              "prowl-cards", "@21", "%7", "feature", "/tmp/repo/wt", "zsh", "codex", "1",
              "card-21", "/tmp/repo/wt/", "/tmp/repo/wt/", "/tmp/repo", "2026-05-29T05:33:58Z",
            ].joined(separator: separator),
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("display-message") {
          return TmuxCommandResult(stdout: "@21\n", stderr: "", exitCode: 0)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true,
      layoutPersistence: TerminalLayoutPersistenceClient(
        loadSnapshot: { nil },
        saveSnapshot: { _ in true },
        clearSnapshot: { true }
      )
    )
    let stream = manager.eventStream()

    await manager.restoreLayoutSnapshot(from: [worktree])

    let event = await nextEvent(stream) { $0 == .layoutRestored(selectedWorktreeID: worktree.id) }
    let state = try #require(manager.stateIfExists(for: worktree.id))
    let restoredTab = try #require(state.tabManager.selectedTabId)
    let surface = try #require(state.surfaceView(for: restoredTab))

    #expect(event == .layoutRestored(selectedWorktreeID: worktree.id))
    #expect(state.tmuxTargetForTesting(restoredTab)?.windowID?.rawValue == "@21")
    #expect(state.tmuxTargetForTesting(restoredTab)?.cardID.rawValue == "card-21")
    #expect(surface.launchCommandForTesting?.contains("attach-session") == true)
    #expect(state.agentDetectionSchedules[surface.id] != nil)
    #expect(state.surfaceAgentStates[surface.id] != nil)
    state.setAgentDetectionEnabled(false)
  }

  @Test func restoreLayoutSnapshotRehydratesSingleLegacyTmuxCard() async throws {
    let separator = "\u{1F}"
    let tabUUID = UUID(uuidString: "267C4DBA-3DBA-4739-AE9C-566EAC1AFBDD")!
    let originalCardID = "23E5CBEA-864D-47BC-9F11-E0699D8E4E38"
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    let snapshot = TerminalLayoutSnapshotPayload(
      selectedWorktreeID: worktree.id,
      worktrees: [
        TerminalLayoutSnapshotPayload.SnapshotWorktree(
          worktreeID: worktree.id,
          selectedTabID: tabUUID.uuidString,
          tabs: [
            TerminalLayoutSnapshotPayload.SnapshotTab(
              tabID: tabUUID.uuidString,
              title: "Yams-MacBook-Pro.local",
              icon: nil,
              splitRoot: .leaf(surfaceID: UUID().uuidString)
            )
          ]
        )
      ]
    )
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        if arguments.contains("list-sessions") {
          return TmuxCommandResult(
            stdout: ["prowl-cards", "1", "prowl-cards"].joined(separator: separator) + "\n",
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("list-windows") {
          return TmuxCommandResult(
            stdout: [
              "prowl-cards", "@21", "%7", "feature", "/tmp/repo/wt", "zsh", "Yams-MacBook-Pro.local", "1",
              originalCardID, worktree.id, "/tmp/repo/wt", "/tmp/repo", "2026-05-29T05:33:58Z",
            ].joined(separator: separator),
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("display-message") {
          return TmuxCommandResult(stdout: "@21\n", stderr: "", exitCode: 0)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true,
      layoutPersistence: TerminalLayoutPersistenceClient(
        loadSnapshot: { snapshot },
        saveSnapshot: { _ in true },
        clearSnapshot: { true }
      )
    )
    let stream = manager.eventStream()

    await manager.restoreLayoutSnapshot(from: [worktree])

    let event = await nextEvent(stream) { $0 == .layoutRestored(selectedWorktreeID: worktree.id) }
    let state = try #require(manager.stateIfExists(for: worktree.id))
    let tabID = TerminalTabID(rawValue: tabUUID)
    let target = try #require(state.tmuxTargetForTesting(tabID))
    let surface = try #require(state.surfaceView(for: tabID))
    let detachedSnapshot = await manager.detachedTmuxCardSnapshot()

    #expect(event == .layoutRestored(selectedWorktreeID: worktree.id))
    #expect(target.cardID.rawValue == originalCardID)
    #expect(target.windowID?.rawValue == "@21")
    #expect(target.paneID?.rawValue == "%7")
    #expect(surface.launchCommandForTesting?.contains("attach-session") == true)
    #expect(surface.launchCommandForTesting?.contains("-CC") == false)
    #expect(detachedSnapshot.candidates.isEmpty)
  }

  @Test func restoreLayoutSnapshotRecreatesMissingSnapshotTmuxTarget() async throws {
    let tabUUID = UUID(uuidString: "3FB907DA-5F9D-4DD7-9302-0418DEEBBDA7")!
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appending(path: "prowl-restore-\(UUID().uuidString)", directoryHint: .isDirectory)
    let repositoryRoot = temporaryRoot.appending(path: "repo", directoryHint: .isDirectory)
    let worktreeDirectory = repositoryRoot.appending(path: "wt", directoryHint: .isDirectory)
    let snapshotDirectory = worktreeDirectory.appending(path: "subdir", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
    let worktree = makeWorktree(
      id: worktreeDirectory.path(percentEncoded: false),
      name: "wt",
      repositoryRootURL: repositoryRoot
    )
    let snapshotCwd = snapshotDirectory.path(percentEncoded: false)
    let normalizedSnapshotCwd = normalizedTestPath(snapshotCwd)
    let repositoryRootPath = repositoryRoot.path(percentEncoded: false)
    let normalizedRepositoryRootPath = normalizedTestPath(repositoryRootPath)
    let recordedArguments = LockIsolated<[[String]]>([])
    let snapshot = TerminalLayoutSnapshotPayload(
      selectedWorktreeID: worktree.id,
      worktrees: [
        TerminalLayoutSnapshotPayload.SnapshotWorktree(
          worktreeID: worktree.id,
          selectedTabID: tabUUID.uuidString,
          tabs: [
            TerminalLayoutSnapshotPayload.SnapshotTab(
              tabID: tabUUID.uuidString,
              title: "restored tab",
              icon: nil,
              splitRoot: .leaf(surfaceID: UUID().uuidString, cwdPath: snapshotCwd),
              tmuxTarget: TerminalLayoutSnapshotPayload.SnapshotTmuxTarget(
                socketPath: "/tmp/prowl-tmux/prowl.sock",
                groupSession: "prowl-cards",
                clientSession: "prowl-tab-3FB907DA5F9D",
                windowID: "@26",
                paneID: "%26"
              )
            )
          ]
        )
      ]
    )
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        recordedArguments.withValue { $0.append(arguments) }
        if arguments.contains("display-message") {
          return TmuxCommandResult(stdout: "", stderr: "no server running", exitCode: 1)
        }
        if arguments.contains("list-sessions") {
          return TmuxCommandResult(stdout: "", stderr: "no server running", exitCode: 1)
        }
        if arguments.contains("new-window") {
          return TmuxCommandResult(stdout: "@41 %42\n", stderr: "", exitCode: 0)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true,
      layoutPersistence: TerminalLayoutPersistenceClient(
        loadSnapshot: { snapshot },
        saveSnapshot: { _ in true },
        clearSnapshot: { true }
      )
    )
    let stream = manager.eventStream()

    await manager.restoreLayoutSnapshot(from: [worktree])

    let event = await nextEvent(stream) { $0 == .layoutRestored(selectedWorktreeID: worktree.id) }
    let state = try #require(manager.stateIfExists(for: worktree.id))
    let tabID = TerminalTabID(rawValue: tabUUID)
    let target = try #require(state.tmuxTargetForTesting(tabID))
    let surface = try #require(state.surfaceView(for: tabID))
    let newWindowArguments = try #require(recordedArguments.value.first { $0.contains("new-window") })
    let metadataArguments = recordedArguments.value.filter { $0.contains("set-window-option") }
    let metadataByOption = Dictionary(
      uniqueKeysWithValues: metadataArguments.compactMap { arguments -> (String, String)? in
        guard arguments.count >= 2 else { return nil }
        return (arguments[arguments.count - 2], arguments[arguments.count - 1])
      }
    )

    #expect(event == .layoutRestored(selectedWorktreeID: worktree.id))
    #expect(target.windowID?.rawValue == "@41")
    #expect(target.paneID?.rawValue == "%42")
    #expect(surface.launchCommandForTesting?.contains("attach-session") == true)
    #expect(newWindowArguments.contains("-c"))
    #expect(newWindowArguments.contains(normalizedSnapshotCwd))
    #expect(metadataArguments.contains { $0.contains("@prowl.worktree_id") && $0.contains(worktree.id) })
    #expect(metadataByOption["@prowl.worktree_path"].map(normalizedTestPath) == normalizedSnapshotCwd)
    #expect(metadataByOption["@prowl.repository_root"].map(normalizedTestPath) == normalizedRepositoryRootPath)
  }

  @Test func restoreLayoutSnapshotUsesCardIDWhenMultipleTmuxCardsMatchWorktree() async throws {
    let separator = "\u{1F}"
    let tabUUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    let snapshot = TerminalLayoutSnapshotPayload(
      worktrees: [
        TerminalLayoutSnapshotPayload.SnapshotWorktree(
          worktreeID: worktree.id,
          selectedTabID: tabUUID.uuidString,
          tabs: [
            TerminalLayoutSnapshotPayload.SnapshotTab(
              tabID: tabUUID.uuidString,
              title: nil,
              icon: nil,
              splitRoot: .leaf(surfaceID: UUID().uuidString)
            )
          ]
        )
      ]
    )
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        if arguments.contains("list-sessions") {
          return TmuxCommandResult(
            stdout: ["prowl-cards", "2", "prowl-cards"].joined(separator: separator) + "\n",
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("list-windows") {
          return TmuxCommandResult(
            stdout: [
              [
                "prowl-cards", "@21", "%21", "other", "/tmp/repo/wt", "zsh", "", "1",
                "other-card", worktree.id, "/tmp/repo/wt", "/tmp/repo", "2026-05-29T05:33:58Z",
              ].joined(separator: separator),
              [
                "prowl-cards", "@22", "%22", "target", "/tmp/repo/wt", "zsh", "", "1",
                tabUUID.uuidString, worktree.id, "/tmp/repo/wt", "/tmp/repo", "2026-05-29T05:33:59Z",
              ].joined(separator: separator),
            ].joined(separator: "\n"),
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("display-message") {
          return TmuxCommandResult(stdout: "@22\n", stderr: "", exitCode: 0)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true,
      layoutPersistence: TerminalLayoutPersistenceClient(
        loadSnapshot: { snapshot },
        saveSnapshot: { _ in true },
        clearSnapshot: { true }
      )
    )

    await manager.restoreLayoutSnapshot(from: [worktree])

    let state = try #require(manager.stateIfExists(for: worktree.id))
    let target = try #require(state.tmuxTargetForTesting(TerminalTabID(rawValue: tabUUID)))

    #expect(target.windowID?.rawValue == "@22")
    #expect(target.paneID?.rawValue == "%22")
  }

  @Test func restoreLayoutSnapshotDoesNotGuessWhenMultipleTmuxCardsMatchWorktree() async throws {
    let separator = "\u{1F}"
    let tabUUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    let snapshot = TerminalLayoutSnapshotPayload(
      worktrees: [
        TerminalLayoutSnapshotPayload.SnapshotWorktree(
          worktreeID: worktree.id,
          selectedTabID: tabUUID.uuidString,
          tabs: [
            TerminalLayoutSnapshotPayload.SnapshotTab(
              tabID: tabUUID.uuidString,
              title: nil,
              icon: nil,
              splitRoot: .leaf(surfaceID: UUID().uuidString)
            )
          ]
        )
      ]
    )
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        if arguments.contains("list-sessions") {
          return TmuxCommandResult(
            stdout: ["prowl-cards", "2", "prowl-cards"].joined(separator: separator) + "\n",
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("list-windows") {
          return TmuxCommandResult(
            stdout: [
              [
                "prowl-cards", "@21", "%21", "one", "/tmp/repo/wt", "zsh", "", "1",
                "other-card-1", worktree.id, "/tmp/repo/wt", "/tmp/repo", "2026-05-29T05:33:58Z",
              ].joined(separator: separator),
              [
                "prowl-cards", "@22", "%22", "two", "/tmp/repo/wt", "zsh", "", "1",
                "other-card-2", worktree.id, "/tmp/repo/wt", "/tmp/repo", "2026-05-29T05:33:59Z",
              ].joined(separator: separator),
            ].joined(separator: "\n"),
            stderr: "",
            exitCode: 0
          )
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      tmuxController: controller,
      usesAnonymousTmux: true,
      layoutPersistence: TerminalLayoutPersistenceClient(
        loadSnapshot: { snapshot },
        saveSnapshot: { _ in true },
        clearSnapshot: { true }
      )
    )

    await manager.restoreLayoutSnapshot(from: [worktree])

    let state = try #require(manager.stateIfExists(for: worktree.id))
    let surface = try #require(state.surfaceView(for: TerminalTabID(rawValue: tabUUID)))

    #expect(state.tmuxTargetForTesting(TerminalTabID(rawValue: tabUUID)) == nil)
    #expect(surface.launchCommandForTesting == nil)
  }

  @Test func persistLayoutSnapshotWithoutTabsClearsSnapshot() async {
    let clearCount = LockIsolated(0)
    let saveCount = LockIsolated(0)
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      layoutPersistence: TerminalLayoutPersistenceClient(
        loadSnapshot: { nil },
        saveSnapshot: { _ in
          saveCount.withValue { $0 += 1 }
          return true
        },
        clearSnapshot: {
          clearCount.withValue { $0 += 1 }
          return true
        }
      )
    )

    await manager.persistLayoutSnapshot()

    #expect(saveCount.value == 0)
    #expect(clearCount.value == 1)
  }

  @Test func pruneKeepsFreestyleStateWhenItHasOpenTabs() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let freestyle = FreestyleTerminal.worktree(homeDirectory: URL(fileURLWithPath: "/tmp"))
    let standardState = manager.state(for: worktree)
    let freestyleState = manager.state(for: freestyle)
    _ = standardState.tabManager.createTab(title: "repo", icon: nil)
    _ = freestyleState.tabManager.createTab(title: "freestyle", icon: nil)

    manager.prune(keeping: [])

    #expect(manager.stateIfExists(for: worktree.id) == nil)
    #expect(manager.stateIfExists(for: FreestyleTerminal.worktreeID) != nil)
  }

  private func makeWorktree(
    id: Worktree.ID = "/tmp/repo/wt-1",
    name: String = "wt-1",
    repositoryRootURL: URL = URL(fileURLWithPath: "/tmp/repo")
  ) -> Worktree {
    Worktree(
      id: id,
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: repositoryRootURL
    )
  }

  private func normalizedTestPath(_ path: String) -> String {
    path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  private func nextEvent(
    _ stream: AsyncStream<TerminalClient.Event>,
    matching predicate: (TerminalClient.Event) -> Bool
  ) async -> TerminalClient.Event? {
    for await event in stream where predicate(event) {
      return event
    }
    return nil
  }

  private func makeNotification(
    id: UUID = UUID(),
    surfaceId: UUID = UUID(),
    createdAt: Date = .distantPast,
    isRead: Bool
  ) -> WorktreeTerminalNotification {
    WorktreeTerminalNotification(
      id: id,
      surfaceId: surfaceId,
      title: "Title",
      body: "Body",
      createdAt: createdAt,
      isRead: isRead
    )
  }

  private func waitForState(
    _ worktreeID: Worktree.ID,
    in manager: WorktreeTerminalManager,
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column
  ) async throws -> WorktreeTerminalState {
    for _ in 0..<100 {
      if let state = manager.stateIfExists(for: worktreeID) {
        return state
      }
      await Task.yield()
    }
    Issue.record(
      "Timed out waiting for terminal state",
      sourceLocation: SourceLocation(
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
      ))
    throw WaitForTestError.timedOut
  }

  private func waitForTabCount(
    _ count: Int,
    in state: WorktreeTerminalState,
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column
  ) async throws -> [TerminalTabID] {
    for _ in 0..<100 {
      let tabIDs = state.tabManager.tabs.map(\.id)
      if tabIDs.count == count {
        return tabIDs
      }
      await Task.yield()
    }
    Issue.record(
      "Timed out waiting for \(count) tab(s)",
      sourceLocation: SourceLocation(
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
      ))
    throw WaitForTestError.timedOut
  }

  private func waitForTmuxBackedTab(
    in state: WorktreeTerminalState,
    excluding tabID: TerminalTabID,
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column
  ) async throws -> TerminalTabID {
    for _ in 0..<200 {
      for candidate in state.tabManager.tabs.map(\.id) where candidate != tabID {
        if state.surfaceView(for: candidate)?.launchCommandForTesting?.contains("attach-session") == true {
          return candidate
        }
      }
      await Task.yield()
    }
    Issue.record(
      "Timed out waiting for tmux-backed tab",
      sourceLocation: SourceLocation(
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
      ))
    throw WaitForTestError.timedOut
  }

  private func waitForTmuxNewWindowAttempt(
    _ gate: TmuxNewWindowGate,
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column
  ) async throws {
    for _ in 0..<100 {
      let arguments = await gate.arguments
      if arguments.contains(where: { $0.contains("new-window") }) {
        return
      }
      await Task.yield()
    }
    Issue.record(
      "Timed out waiting for tmux new-window attempt",
      sourceLocation: SourceLocation(
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
      ))
    throw WaitForTestError.timedOut
  }

}

private enum WaitForTestError: Error {
  case timedOut
}

private actor TmuxNewWindowGate {
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var isReleased = false
  private(set) var arguments: [[String]] = []

  func record(_ arguments: [String]) {
    self.arguments.append(arguments)
  }

  func waitForRelease() async {
    guard !isReleased else { return }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func release() {
    isReleased = true
    let pendingContinuations = continuations
    continuations.removeAll()
    for continuation in pendingContinuations {
      continuation.resume()
    }
  }
}

private actor TmuxCommandRecorder {
  private var recordedArguments: [[String]] = []

  var arguments: [[String]] {
    recordedArguments
  }

  func record(_ arguments: [String]) {
    recordedArguments.append(arguments)
  }
}

private actor TmuxNewWindowOutputQueue {
  private var outputs: [String]

  init(_ outputs: [String]) {
    self.outputs = outputs
  }

  func next() -> String {
    outputs.removeFirst()
  }
}
