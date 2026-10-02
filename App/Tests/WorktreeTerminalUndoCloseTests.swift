import Clocks
import Foundation
import GhosttyKit
import ProwlCLIShared
import Testing

@testable import supacode

/// Undo for pane and tab closes (docs-ai 069): the manager-level flow from a
/// close through ⌘Z / ⌘⇧Z, expiry, and invalidation.
@MainActor
@Suite(.serialized)
struct WorktreeTerminalUndoCloseTests {
  @Test func closedTabComesBackAtItsIndexWithTheSameSurface() throws {
    let fixture = makeFixture()
    let state = fixture.state
    let first = try #require(state.createTab())
    let second = try #require(state.createTab())
    let third = try #require(state.createTab())
    state.selectTab(second)
    let surfaceID = try #require(state.focusedSurfaceId(in: second))
    let view = try #require(state.surfaceView(for: surfaceID))
    let handleBefore = state.paneHandle(for: surfaceID)

    #expect(state.closeTab(second))
    #expect(state.tabManager.tabs.map(\.id) == [first, third])
    #expect(state.surfaceView(for: surfaceID) == nil)
    #expect(view.isPendingClose)
    #expect(fixture.manager.closeUndoStack.canUndo)

    #expect(fixture.manager.undoClose())

    #expect(state.tabManager.tabs.map(\.id) == [first, second, third])
    #expect(state.tabManager.selectedTabId == second)
    #expect(state.surfaceView(for: surfaceID) === view)
    #expect(state.focusedSurfaceId(in: second) == surfaceID)
    #expect(!view.isPendingClose)
    #expect(state.paneHandle(for: surfaceID) != handleBefore)
    #expect(!fixture.manager.closeUndoStack.canUndo)
    #expect(fixture.manager.closeUndoStack.canRedo)
  }

  @Test func closedPaneComesBackInItsSplitPosition() throws {
    let fixture = makeFixture()
    let state = fixture.state
    let tab = try #require(state.createTab())
    let anchor = try #require(state.focusedSurfaceId(in: tab))
    let pane = try state.createSplit(of: anchor, direction: .right, initialInput: nil).get()
    let before = state.splitTree(for: tab)
    let view = try #require(state.surfaceView(for: pane))

    #expect(state.closeSurface(id: pane))
    #expect(state.splitTree(for: tab).leaves().map(\.id) == [anchor])
    #expect(state.focusedSurfaceId(in: tab) == anchor)

    #expect(fixture.manager.undoClose())

    let after = state.splitTree(for: tab)
    #expect(after.structuralIdentity == before.structuralIdentity)
    #expect(after.leaves().map(\.id) == [anchor, pane])
    #expect(state.surfaceView(for: pane) === view)
    #expect(state.focusedSurfaceId(in: tab) == pane)
  }

  @Test func undoWithNothingRecordedFallsThrough() {
    let fixture = makeFixture()
    #expect(!fixture.manager.undoClose())
    #expect(!fixture.manager.redoClose())
  }

  @Test func closeExpiresAfterTheGhosttyTimeout() async throws {
    let fixture = makeFixture()
    let state = fixture.state
    let tab = try #require(state.createTab())
    let surfaceID = try #require(state.focusedSurfaceId(in: tab))
    let view = try #require(state.surfaceView(for: surfaceID))

    #expect(state.closeTab(tab))
    #expect(view.isPendingClose)

    await fixture.clock.advance(by: .seconds(5))
    await settle()

    #expect(!fixture.manager.closeUndoStack.canUndo)
    #expect(!view.isPendingClose)
    #expect(!fixture.manager.undoClose())
    #expect(state.tabManager.tabs.isEmpty)
  }

  @Test func processExitDuringGraceDropsTheRecord() throws {
    let fixture = makeFixture()
    let state = fixture.state
    let tab = try #require(state.createTab())
    let surfaceID = try #require(state.focusedSurfaceId(in: tab))
    let view = try #require(state.surfaceView(for: surfaceID))

    #expect(state.closeTab(tab))
    view.bridge.closeSurface(processAlive: false)

    #expect(!fixture.manager.closeUndoStack.canUndo)
    #expect(!view.isPendingClose)
    #expect(!fixture.manager.undoClose())
  }

  /// Ghostty's close callback carries `needsConfirmQuit()`, which is false for
  /// an idle shell at its prompt: that is the plain ⌘W case and must be undoable.
  @Test func idleShellCloseRequestIsRecorded() throws {
    let fixture = makeFixture()
    let state = fixture.state
    let tab = try #require(state.createTab())
    let surfaceID = try #require(state.focusedSurfaceId(in: tab))
    let view = try #require(state.surfaceView(for: surfaceID))

    #expect(state.handleCloseRequest(for: view, processAlive: false))

    #expect(view.isPendingClose)
    #expect(fixture.manager.closeUndoStack.canUndo)
    #expect(fixture.manager.undoClose())
    #expect(state.surfaceView(for: surfaceID) === view)
  }

  /// A shell that exited reports `show_child_exited` before its close request.
  @Test func deadProcessCloseIsNotRecorded() throws {
    let fixture = makeFixture()
    let state = fixture.state
    let tab = try #require(state.createTab())
    let surfaceID = try #require(state.focusedSurfaceId(in: tab))
    let view = try #require(state.surfaceView(for: surfaceID))
    reportChildExit(on: view)

    #expect(state.handleCloseRequest(for: view, processAlive: false))

    #expect(!view.isPendingClose)
    #expect(!fixture.manager.closeUndoStack.canUndo)
  }

  @Test func autoCloseOnSuccessIsNotRecorded() throws {
    let fixture = makeFixture()
    let state = fixture.state
    let tab = try #require(state.createTab())
    let surfaceID = try #require(state.focusedSurfaceId(in: tab))
    let view = try #require(state.surfaceView(for: surfaceID))

    #expect(state.handleCloseRequest(for: view, processAlive: false, retainForUndo: false))

    #expect(!view.isPendingClose)
    #expect(!fixture.manager.closeUndoStack.canUndo)
  }

  @Test func zeroTimeoutKeepsFreeOnClose() throws {
    let fixture = makeFixture()
    let state = fixture.state
    state.undoCloseTimeout = .zero
    let tab = try #require(state.createTab())
    let surfaceID = try #require(state.focusedSurfaceId(in: tab))
    let view = try #require(state.surfaceView(for: surfaceID))

    #expect(state.closeTab(tab))

    #expect(!view.isPendingClose)
    #expect(!fixture.manager.closeUndoStack.canUndo)
  }

  @Test func batchCloseUndoesAsOneEntry() throws {
    let fixture = makeFixture()
    let state = fixture.state
    let first = try #require(state.createTab())
    let second = try #require(state.createTab())
    let third = try #require(state.createTab())
    state.selectTab(first)

    state.closeOtherTabs(keeping: first)
    #expect(state.tabManager.tabs.map(\.id) == [first])

    #expect(fixture.manager.undoClose())

    #expect(state.tabManager.tabs.map(\.id) == [first, second, third])
    #expect(state.tabManager.selectedTabId == first)
    #expect(!fixture.manager.closeUndoStack.canUndo)
  }

  @Test func redoClosesAgainAndStaysUndoable() throws {
    let fixture = makeFixture()
    let state = fixture.state
    let first = try #require(state.createTab())
    let second = try #require(state.createTab())

    #expect(state.closeTab(second))
    #expect(fixture.manager.undoClose())
    #expect(fixture.manager.redoClose())

    #expect(state.tabManager.tabs.map(\.id) == [first])
    #expect(fixture.manager.closeUndoStack.canUndo)
    #expect(!fixture.manager.closeUndoStack.canRedo)

    #expect(fixture.manager.undoClose())
    #expect(state.tabManager.tabs.map(\.id) == [first, second])
  }

  @Test func paneRecordIsDroppedWhenTheTabChangedShape() throws {
    let fixture = makeFixture()
    let state = fixture.state
    let tab = try #require(state.createTab())
    let anchor = try #require(state.focusedSurfaceId(in: tab))
    let pane = try state.createSplit(of: anchor, direction: .right, initialInput: nil).get()
    let view = try #require(state.surfaceView(for: pane))

    #expect(state.closeSurface(id: pane))
    _ = try state.createSplit(of: anchor, direction: .down, initialInput: nil).get()

    #expect(!fixture.manager.undoClose())
    #expect(!view.isPendingClose)
    #expect(state.splitTree(for: tab).leaves().count == 2)
    #expect(!fixture.manager.closeUndoStack.canUndo)
  }

  @Test func pruneFreesRetainedSurfacesOfRemovedWorktrees() throws {
    let fixture = makeFixture()
    let state = fixture.state
    let tab = try #require(state.createTab())
    let surfaceID = try #require(state.focusedSurfaceId(in: tab))
    let view = try #require(state.surfaceView(for: surfaceID))
    #expect(state.closeTab(tab))

    fixture.manager.prune(keeping: [])

    #expect(!view.isPendingClose)
    #expect(!fixture.manager.closeUndoStack.canUndo)
  }

  @Test func restoringTheLastTabReopensTheWorktreeAndReportsTheTab() async throws {
    let fixture = makeFixture()
    let state = fixture.state
    let tab = try #require(state.createTab())
    let stream = fixture.manager.eventStream()
    #expect(state.closeTab(tab))

    #expect(fixture.manager.undoClose())

    var seen: [TerminalClient.Event] = []
    for await event in stream {
      seen.append(event)
      if case .tabRestored = event { break }
    }
    #expect(seen.contains(.tabCreated(worktreeID: fixture.worktree.id)))
    #expect(seen.last == .tabRestored(worktreeID: fixture.worktree.id, tabID: tab))
  }

  @Test func batchRestoreReportsTheTabThatWasSelected() async throws {
    let fixture = makeFixture()
    let state = fixture.state
    let first = try #require(state.createTab())
    let second = try #require(state.createTab())
    state.selectTab(second)
    let stream = fixture.manager.eventStream()
    state.closeAllTabs()

    #expect(fixture.manager.undoClose())

    var reported: TerminalTabID?
    for await event in stream {
      if case .tabRestored(_, let tabID) = event {
        reported = tabID
        break
      }
    }
    #expect(reported == second)
    #expect(state.tabManager.tabs.map(\.id) == [first, second])
    #expect(state.tabManager.selectedTabId == second)
  }

  // Round 1 review findings (docs-ai 069): pinned red before the fixes.

  @Test func restoringAPaneFromAnotherTabSelectsItsTab() throws {
    let fixture = makeFixture()
    let state = fixture.state
    let first = try #require(state.createTab())
    let anchor = try #require(state.focusedSurfaceId(in: first))
    let pane = try state.createSplit(of: anchor, direction: .right, initialInput: nil).get()
    let second = try #require(state.createTab())

    state.selectTab(first)
    #expect(state.closeSurface(id: pane))
    state.selectTab(second)

    #expect(fixture.manager.undoClose())

    #expect(state.tabManager.selectedTabId == first)
    #expect(state.focusedSurfaceId(in: first) == pane)
  }

  @Test func restoredProfileSurfaceKeepsItsLaunchProfileAndHook() throws {
    let fixture = makeFixture()
    let state = fixture.state
    _ = try #require(state.createTab())
    let launched = try launchProfile(in: state, cwd: fixture.worktree.workingDirectory)
    let profile = try #require(state.launchProfilesBySurface[launched.surfaceID])
    #expect(fixture.manager.hasManagedHookForTesting(surfaceID: launched.surfaceID))

    #expect(state.closeTab(launched.tabID))
    #expect(state.launchProfilesBySurface[launched.surfaceID] == nil)
    #expect(!fixture.manager.hasManagedHookForTesting(surfaceID: launched.surfaceID))

    #expect(fixture.manager.undoClose())

    #expect(state.launchProfilesBySurface[launched.surfaceID] == profile)
    #expect(fixture.manager.hasManagedHookForTesting(surfaceID: launched.surfaceID))
  }

  @Test func paneRecordIsDroppedWhenPanesWereRearranged() throws {
    let fixture = makeFixture()
    let state = fixture.state
    let tab = try #require(state.createTab())
    let paneA = try #require(state.focusedSurfaceId(in: tab))
    let paneB = try state.createSplit(of: paneA, direction: .right, initialInput: nil).get()
    let paneC = try state.createSplit(of: paneB, direction: .right, initialInput: nil).get()
    let view = try #require(state.surfaceView(for: paneC))

    #expect(state.closeSurface(id: paneC))
    state.performSplitOperation(.drop(payloadId: paneB, destinationId: paneA, zone: .left), in: tab)
    let rearranged = state.splitTree(for: tab)
    #expect(rearranged.leaves().map(\.id) == [paneB, paneA])

    #expect(!fixture.manager.undoClose())
    #expect(!view.isPendingClose)
    #expect(state.splitTree(for: tab).structuralIdentity == rearranged.structuralIdentity)
  }

  @Test func layoutResetDiscardsRetainedRecords() throws {
    let fixture = makeFixture()
    let state = fixture.state
    let tab = try #require(state.createTab())
    let surfaceID = try #require(state.focusedSurfaceId(in: tab))
    let view = try #require(state.surfaceView(for: surfaceID))
    #expect(state.closeTab(tab))
    #expect(fixture.manager.closeUndoStack.canUndo)

    state.closeAllSurfaces()

    #expect(!fixture.manager.closeUndoStack.canUndo)
    #expect(!view.isPendingClose)
    #expect(!fixture.manager.undoClose())
  }

  // Round 2 review findings.

  @Test func retainedProfileCloseKeepsTheForwardingRecordUntilTheSurfaceIsFreed() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "undo-forwarding-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let fixture = makeFixture(forwardingRecordBaseDirectory: base)
    let state = fixture.state
    let store = try #require(fixture.manager.forwardingRecordStoreForTesting())
    let record = try store.create(argv: ["/tmp/notifier"])
    let launched = try launchProfile(in: state, cwd: fixture.worktree.workingDirectory, forwardingRecord: record)

    #expect(state.closeTab(launched.tabID))
    #expect(!store.isRetired(record))

    #expect(fixture.manager.undoClose())
    #expect(!store.isRetired(record))
    #expect(fixture.manager.hasManagedHookForTesting(surfaceID: launched.surfaceID))

    #expect(state.closeTab(launched.tabID))
    await fixture.clock.advance(by: .seconds(5))
    await settle()
    #expect(store.isRetired(record))
  }

  @Test func restoringAPaneInCanvasRequestsVisibleOcclusion() throws {
    let fixture = makeFixture()
    let state = fixture.state
    state.isCanvasManaged = true
    let tab = try #require(state.createTab())
    let anchor = try #require(state.focusedSurfaceId(in: tab))
    let pane = try state.createSplit(of: anchor, direction: .right, initialInput: nil).get()
    let view = try #require(state.surfaceView(for: pane))
    view.attachmentStateForTesting = { (hasSuperview: true, hasWindow: true) }
    var applied: [Bool] = []
    view.onOcclusionAppliedForTesting = { applied.append($0) }

    #expect(state.closeSurface(id: pane))
    #expect(applied.last == false)

    #expect(fixture.manager.undoClose())
    #expect(applied.last == true)
  }

  // Round 4 review finding: child exit without a close request
  // (Ghostty `wait-after-command`).

  @Test func childExitDuringGraceDropsTheRecord() throws {
    let fixture = makeFixture()
    let state = fixture.state
    let tab = try #require(state.createTab())
    let surfaceID = try #require(state.focusedSurfaceId(in: tab))
    let view = try #require(state.surfaceView(for: surfaceID))

    #expect(state.closeTab(tab))
    reportChildExit(on: view)

    #expect(!fixture.manager.closeUndoStack.canUndo)
    #expect(!view.isPendingClose)
    #expect(!fixture.manager.undoClose())
  }

  @Test func closingAnExitedTerminalIsNotRecorded() throws {
    let fixture = makeFixture()
    let state = fixture.state
    let tab = try #require(state.createTab())
    let surfaceID = try #require(state.focusedSurfaceId(in: tab))
    let view = try #require(state.surfaceView(for: surfaceID))
    reportChildExit(on: view)

    #expect(state.closeTab(tab))

    #expect(!view.isPendingClose)
    #expect(!fixture.manager.closeUndoStack.canUndo)
  }

  @Test func closingATabKeepsOnlyItsLivingPanesRestorable() throws {
    let fixture = makeFixture()
    let state = fixture.state
    let tab = try #require(state.createTab())
    let anchor = try #require(state.focusedSurfaceId(in: tab))
    let exited = try state.createSplit(of: anchor, direction: .right, initialInput: nil).get()
    let exitedView = try #require(state.surfaceView(for: exited))
    let livingView = try #require(state.surfaceView(for: anchor))
    reportChildExit(on: exitedView)

    #expect(state.closeTab(tab))
    #expect(!exitedView.isPendingClose)
    #expect(livingView.isPendingClose)

    #expect(fixture.manager.undoClose())
    #expect(state.splitTree(for: tab).leaves().map(\.id) == [anchor])
    #expect(state.surfaceView(for: exited) == nil)
    #expect(state.focusedSurfaceId(in: tab) == anchor)
  }

  private func reportChildExit(on view: GhosttySurfaceView) {
    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_SHOW_CHILD_EXITED
    action.action.child_exited.exit_code = 0
    _ = view.bridge.handleAction(target: ghostty_target_s(), action: action)
  }

  private struct Fixture {
    let manager: WorktreeTerminalManager
    let state: WorktreeTerminalState
    let worktree: Worktree
    let clock: TestClock<Duration>
  }

  private func makeFixture(forwardingRecordBaseDirectory: URL? = nil) -> Fixture {
    let clock = TestClock()
    let manager: WorktreeTerminalManager
    if let forwardingRecordBaseDirectory {
      manager = WorktreeTerminalManager(
        runtime: GhosttyRuntime(),
        forwardingRecordBaseDirectory: forwardingRecordBaseDirectory,
        undoCloseClock: clock,
        skipsSurfaceCreationForTesting: true
      )
    } else {
      manager = WorktreeTerminalManager(
        runtime: GhosttyRuntime(),
        undoCloseClock: clock,
        skipsSurfaceCreationForTesting: true
      )
    }
    let worktree = Worktree(
      id: "/tmp/repo/wt-1",
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    return Fixture(manager: manager, state: manager.state(for: worktree), worktree: worktree, clock: clock)
  }

  private func launchProfile(
    in state: WorktreeTerminalState,
    cwd: URL,
    forwardingRecord: CodexForwardingRecord? = nil
  ) throws -> LaunchedSurface {
    let registration = AgentHookLaunchRegistration(
      token: "token-undo",
      runtime: .codex,
      launchCWD: cwd,
      nativeEvents: ["agent-turn-complete": .turnEnded],
      coveredEvents: [.turnEnded],
      forwardingRecord: forwardingRecord
    )
    let plan = AgentProfileLaunchPlan(
      profileID: UUID(),
      profileName: "Codex · Bound",
      runtime: .codex,
      invocation: AgentInvocation(executable: "codex", arguments: []),
      hookRegistration: registration,
      commandEnvironmentTokens: [],
      placement: .tab,
      splitDirection: .right,
      surfaceEnvironment: [:],
      dedicatedHome: nil
    )
    return try state.launchAgentProfile(
      AgentProfileLaunchRequest(plan: plan, placement: .tab(background: false))
    ).get()
  }

  private func settle() async {
    for _ in 0..<10 {
      await Task.yield()
    }
  }
}
