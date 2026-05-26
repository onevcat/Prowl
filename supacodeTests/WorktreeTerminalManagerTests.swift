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

  @Test func newEmptyTabStartsColdAgentDetection() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab())
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))

    #expect(state.agentDetectionSchedules[surfaceId] == nil)
    #expect(state.agentDetectionTasks[surfaceId] == nil)
  }

  @Test func wakingSurfaceStartsWarmAgentDetection() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab())
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))

    state.wakeAgentDetection(forSurfaceID: surfaceId)

    let schedule = try #require(state.agentDetectionSchedules[surfaceId])
    #expect(schedule.nextInterval(now: Date()) != nil)
    #expect(state.agentDetectionTasks[surfaceId] != nil)

    state.cleanupAllAgentDetectionState()
  }

  @Test func initialInputStartsWarmAgentDetection() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab(initialInput: "codex\n"))
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))

    let schedule = try #require(state.agentDetectionSchedules[surfaceId])
    #expect(schedule.nextInterval(now: Date()) != nil)
    #expect(state.agentDetectionTasks[surfaceId] != nil)

    state.cleanupAllAgentDetectionState()
  }

  @Test func firstTabUsesTabSurfaceContext() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab())
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))
    let surface = try #require(state.surfaceView(for: surfaceId))

    #expect(surface.surfaceContextForTesting == GHOSTTY_SURFACE_CONTEXT_TAB)
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

  @Test func closeSurfaceReturnsActualRemovalResult() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab())
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))

    #expect(state.closeSurface(id: surfaceId, confirmation: .skip) == true)
    #expect(state.surfaceView(for: surfaceId) == nil)
    #expect(state.tabManager.tabs.isEmpty)
    #expect(state.closeSurface(id: surfaceId, confirmation: .skip) == false)
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
    #expect(launchCommand.contains("-CC attach-session"))
    #expect(state.tmuxTargetForTesting(tabID)?.windowID == TmuxWindowID(rawValue: "@7"))
    #expect(state.isTmuxBacked(tabID) == true)
  }

  @Test func plainTabReportsNotTmuxBacked() {
    let state = WorktreeTerminalState(runtime: GhosttyRuntime(), worktree: makeWorktree())

    let tabID = state.createTab()

    #expect(tabID.map { state.isTmuxBacked($0) } == false)
  }

  @Test func closingTmuxBackedTabDoesNotKillWindow() async throws {
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
    let state = try #require(manager.stateIfExists(for: worktree.id))
    state.closeTab(tabID)

    let arguments = await recorder.arguments
    #expect(arguments.contains { $0.contains("kill-window") } == false)
    #expect(state.surfaceView(for: tabID) == nil)
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
    let disabledTabID = try #require(await manager.createTabForTesting(in: disabledWorktree, runSetupScriptIfNew: false))

    let enabledState = try #require(manager.stateIfExists(for: enabledWorktree.id))
    let disabledState = try #require(manager.stateIfExists(for: disabledWorktree.id))
    let enabledSurface = try #require(enabledState.surfaceView(for: enabledTabID))
    let disabledSurface = try #require(disabledState.surfaceView(for: disabledTabID))

    #expect(enabledSurface.launchCommandForTesting?.contains("-CC attach-session") == true)
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

    #expect(secondSurface.launchCommandForTesting?.contains("-CC attach-session") == true)
    #expect(state.tmuxTargetForTesting(secondTabID)?.windowID == TmuxWindowID(rawValue: "@7"))
  }

  @Test func tmuxCreationDoesNotResurrectClosedPendingTab() async throws {
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
    let pendingTabID = try #require(await waitForTabCount(1, in: state).first)

    state.closeTab(pendingTabID)
    await gate.release()

    let createdTabID = await createTask.value

    #expect(createdTabID == nil)
    #expect(state.tabManager.tabs.isEmpty)
    #expect(state.surfaceView(for: pendingTabID) == nil)
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
    _ = try #require(await waitForTabCount(1, in: state).first)

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

    #expect(restoredSurface.launchCommandForTesting?.contains("-CC attach-session") == true)
    #expect(restoredTarget.windowID == TmuxWindowID(rawValue: "@7"))
    #expect(restoredTarget.paneID == TmuxPaneID(rawValue: "%9"))
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

  @Test func restoreLayoutSnapshotEmitsRestoredNilWhenSnapshotMissing() async {
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      layoutPersistence: TerminalLayoutPersistenceClient(
        loadSnapshot: { nil },
        saveSnapshot: { _ in true },
        clearSnapshot: { true }
      )
    )
    let stream = manager.eventStream()

    await manager.restoreLayoutSnapshot(from: [makeWorktree()])

    let event = await nextEvent(stream) { event in
      event == .layoutRestored(selectedWorktreeID: nil)
    }

    #expect(event == .layoutRestored(selectedWorktreeID: nil))
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
    Issue.record("Timed out waiting for terminal state", sourceLocation: SourceLocation(
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
    Issue.record("Timed out waiting for \(count) tab(s)", sourceLocation: SourceLocation(
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
        if state.surfaceView(for: candidate)?.launchCommandForTesting?.contains("-CC attach-session") == true {
          return candidate
        }
      }
      await Task.yield()
    }
    Issue.record("Timed out waiting for tmux-backed tab", sourceLocation: SourceLocation(
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
