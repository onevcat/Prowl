import Foundation
import GhosttyKit
import Testing

@testable import supacode

@MainActor
struct WorktreeTerminalStateViewedSurfaceTests {
  @Test func surfaceIsViewedWhenSelectedFocusedAndWindowActive() {
    let (state, surfaceId) = makeViewedState()

    #expect(state.isViewedSurface(surfaceId))
  }

  @Test func surfaceIsNotViewedWhenWindowStateIsUnknown() {
    let (state, surfaceId) = makeViewedState()
    state.lastWindowIsKey = nil
    state.lastWindowIsVisible = nil

    #expect(!state.isViewedSurface(surfaceId))
  }

  @Test func surfaceIsNotViewedWhenWindowIsNotKey() {
    let (state, surfaceId) = makeViewedState()
    state.lastWindowIsKey = false

    #expect(!state.isViewedSurface(surfaceId))
  }

  @Test func surfaceIsNotViewedWhenCanvasManaged() {
    // Canvas mode tears down the normal-mode window observers, so the window
    // flags freeze at their pre-canvas values; a stale `true` must not mute
    // notifications while the app is in the background.
    let (state, surfaceId) = makeViewedState()
    state.isCanvasManaged = true

    #expect(!state.isViewedSurface(surfaceId))
  }

  @Test func differentSurfaceIsNotViewed() {
    let (state, _) = makeViewedState()

    #expect(!state.isViewedSurface(UUID()))
  }

  @Test func inactiveFocusedCompletionPollRemainsUnread() async {
    let fixture = makeDetectionFixture()
    fixture.state.lastWindowIsKey = false
    fixture.state.surfaceAgentStates[fixture.surface.id] = PaneAgentState(
      detectedAgent: .claude,
      state: .working,
      seen: true
    )
    fixture.state.agentDetectionPresenceBySurface[fixture.surface.id] = AgentDetectionPresence(
      currentAgent: .claude
    )
    fixture.state.lastAgentScreenScanBySurface[fixture.surface.id] = WorktreeTerminalState.AgentScreenScan(
      agent: .claude,
      text: "",
      detection: AgentScreenDetection(state: .idle, reason: .legacyDetector)
    )

    #expect(await fixture.state.detectAgentState(for: fixture.surface, tabId: fixture.tabID))
    #expect(fixture.state.surfaceAgentStates[fixture.surface.id]?.displayState == .done)
  }

  @Test func inactiveFocusBookkeepingDoesNotAcknowledgeCompletion() {
    let fixture = makeDetectionFixture()
    fixture.state.lastWindowIsKey = false
    fixture.state.surfaceAgentStates[fixture.surface.id] = PaneAgentState(
      detectedAgent: .claude,
      state: .idle,
      seen: false
    )

    fixture.state.recordActiveSurface(fixture.surface, in: fixture.tabID)

    #expect(fixture.state.surfaceAgentStates[fixture.surface.id]?.displayState == .done)
  }

  enum ViewingCondition: CaseIterable {
    case viewed, inactive, hidden, unknown, canvas, otherWorktree, otherPane, otherTab
  }

  @Test(arguments: ViewingCondition.allCases, [AgentRawState.working, .blocked])
  func completionPollingRequiresViewedSurface(
    condition: ViewingCondition,
    previousState: AgentRawState
  ) async {
    let fixture = makeDetectionFixture()
    apply(condition, to: fixture.state)
    preparePoll(
      fixture,
      previous: PaneAgentState(detectedAgent: .claude, state: previousState, seen: true),
      detected: .idle
    )

    #expect(await fixture.state.detectAgentState(for: fixture.surface, tabId: fixture.tabID))
    #expect(
      fixture.state.surfaceAgentStates[fixture.surface.id]?.displayState
        == (condition == .viewed ? .idle : .done)
    )
  }

  @Test(arguments: ViewingCondition.allCases)
  func automaticAcknowledgementRequiresViewedSurface(condition: ViewingCondition) {
    let fixture = makeDetectionFixture()
    apply(condition, to: fixture.state)
    fixture.state.surfaceAgentStates[fixture.surface.id] = PaneAgentState(
      detectedAgent: .claude,
      state: .idle,
      seen: false
    )

    fixture.state.markAgentSeen(surfaceID: fixture.surface.id)

    #expect(
      fixture.state.surfaceAgentStates[fixture.surface.id]?.displayState
        == (condition == .viewed ? .idle : .done)
    )
  }

  @Test func inactiveStableIdlePollDoesNotCreateCompletion() async {
    let fixture = makeDetectionFixture()
    fixture.state.lastWindowIsKey = false
    preparePoll(
      fixture,
      previous: PaneAgentState(detectedAgent: .claude, state: .idle, seen: true),
      detected: .idle
    )

    #expect(await fixture.state.detectAgentState(for: fixture.surface, tabId: fixture.tabID))
    #expect(fixture.state.surfaceAgentStates[fixture.surface.id]?.displayState == .idle)
  }

  @Test func inactiveUnreadStateSurvivesBlockedRoundTrip() async {
    let fixture = makeDetectionFixture()
    fixture.state.lastWindowIsKey = false
    preparePoll(
      fixture,
      previous: PaneAgentState(detectedAgent: .claude, state: .idle, seen: false),
      detected: .blocked
    )

    #expect(await fixture.state.detectAgentState(for: fixture.surface, tabId: fixture.tabID))
    #expect(fixture.state.surfaceAgentStates[fixture.surface.id]?.seen == false)

    prepareDetection(fixture, detected: .idle)
    #expect(await fixture.state.detectAgentState(for: fixture.surface, tabId: fixture.tabID))
    #expect(fixture.state.surfaceAgentStates[fixture.surface.id]?.displayState == .done)
  }

  @Test func returningToViewedSurfaceAcknowledgesCompletion() {
    let fixture = makeDetectionFixture()
    fixture.state.lastWindowIsKey = false
    fixture.state.surfaceAgentStates[fixture.surface.id] = PaneAgentState(
      detectedAgent: .claude,
      state: .idle,
      seen: false
    )
    fixture.state.markAgentSeen(surfaceID: fixture.surface.id)
    #expect(fixture.state.surfaceAgentStates[fixture.surface.id]?.displayState == .done)

    fixture.state.lastWindowIsKey = true
    fixture.state.markAgentSeen(surfaceID: fixture.surface.id)
    #expect(fixture.state.surfaceAgentStates[fixture.surface.id]?.displayState == .idle)
  }

  @Test(arguments: [false, true])
  func acknowledgementDuringSessionLookupIsPreserved(metadataChanges: Bool) async {
    let fixture = makeDetectionFixture()
    fixture.state.lastWindowIsKey = false
    preparePoll(
      fixture,
      previous: PaneAgentState(
        detectedAgent: .claude, fallbackState: .idle, state: .idle, seen: false),
      detected: .idle
    )
    let session =
      metadataChanges ? AgentSession(id: "resolved", transcriptPath: nil, source: .recentFile) : nil
    let (started, signalStarted) = AsyncStream<Void>.makeStream()
    let (resume, signalResume) = AsyncStream<Void>.makeStream()
    let poll = Task {
      await fixture.state.detectAgentState(for: fixture.surface, tabId: fixture.tabID) {
        _, _, _, _, _ in
        signalStarted.yield(())
        signalStarted.finish()
        for await _ in resume { break }
        return (session, 0)
      }
    }
    for await _ in started { break }
    fixture.state.lastWindowIsKey = true
    fixture.state.markAgentSeen(surfaceID: fixture.surface.id)
    let acknowledgedAt = fixture.state.surfaceAgentStates[fixture.surface.id]?.lastChangedAt
    fixture.state.lastWindowIsKey = false
    signalResume.yield(())
    signalResume.finish()

    #expect(await poll.value)
    #expect(fixture.state.surfaceAgentStates[fixture.surface.id]?.displayState == .idle)
    #expect(fixture.state.surfaceAgentStates[fixture.surface.id]?.lastChangedAt == acknowledgedAt)
    #expect(fixture.state.surfaceAgentStates[fixture.surface.id]?.session == session)

    preparePoll(
      fixture,
      previous: PaneAgentState(detectedAgent: .claude, state: .working, seen: true),
      detected: .idle
    )
    #expect(await fixture.state.detectAgentState(for: fixture.surface, tabId: fixture.tabID))
    #expect(fixture.state.surfaceAgentStates[fixture.surface.id]?.displayState == .done)
  }

  @Test func stateChangedDuringSessionLookupIsNotOverwritten() async {
    let fixture = makeDetectionFixture()
    preparePoll(
      fixture,
      previous: PaneAgentState(detectedAgent: .claude, state: .idle, seen: false),
      detected: .idle
    )
    let (started, signalStarted) = AsyncStream<Void>.makeStream()
    let (resume, signalResume) = AsyncStream<Void>.makeStream()
    let poll = Task {
      await fixture.state.detectAgentState(for: fixture.surface, tabId: fixture.tabID) {
        _, _, _, _, _ in
        signalStarted.yield(())
        signalStarted.finish()
        for await _ in resume { break }
        return (nil, 0)
      }
    }
    for await _ in started { break }
    let newer = PaneAgentState(detectedAgent: .claude, state: .working, seen: true)
    fixture.state.surfaceAgentStates[fixture.surface.id] = newer
    signalResume.yield(())
    signalResume.finish()

    #expect(await poll.value)
    #expect(fixture.state.surfaceAgentStates[fixture.surface.id] == newer)
  }

  private func makeViewedState() -> (WorktreeTerminalState, UUID) {
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: Worktree(
        id: "/tmp/repo/wt-1",
        name: "wt-1",
        detail: "",
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
        repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
      )
    )
    let tabId = state.tabManager.createTab(title: "tab", icon: nil)
    state.tabManager.selectTab(tabId)
    let surfaceId = UUID()
    state.focusedSurfaceIdByTab[tabId] = surfaceId
    state.isSelected = { true }
    state.lastWindowIsKey = true
    state.lastWindowIsVisible = true
    return (state, surfaceId)
  }

  private struct DetectionFixture {
    let state: WorktreeTerminalState
    let tabID: TerminalTabID
    let surface: GhosttySurfaceView
  }

  private func makeDetectionFixture() -> DetectionFixture {
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: Worktree(
        id: "/tmp/repo/wt-1",
        name: "wt-1",
        detail: "",
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
        repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
      )
    )
    let surface = GhosttySurfaceView(
      runtime: state.runtime,
      workingDirectory: state.worktree.workingDirectory,
      fontSize: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    let tabID = state.tabManager.createTab(title: "tab", icon: nil)
    state.tabManager.selectTab(tabID)
    state.surfaces[surface.id] = surface
    state.trees[tabID] = SplitTree<GhosttySurfaceView>(view: surface)
    state.focusedSurfaceIdByTab[tabID] = surface.id
    state.isSelected = { true }
    state.lastWindowIsKey = true
    state.lastWindowIsVisible = true
    return DetectionFixture(state: state, tabID: tabID, surface: surface)
  }

  private func apply(_ condition: ViewingCondition, to state: WorktreeTerminalState) {
    switch condition {
    case .viewed:
      break
    case .inactive:
      state.lastWindowIsKey = false
    case .hidden:
      state.lastWindowIsVisible = false
    case .unknown:
      state.lastWindowIsKey = nil
      state.lastWindowIsVisible = nil
    case .canvas:
      state.isCanvasManaged = true
    case .otherWorktree:
      state.isSelected = { false }
    case .otherPane:
      if let tabID = state.tabManager.selectedTabId {
        state.focusedSurfaceIdByTab[tabID] = UUID()
      }
    case .otherTab:
      let tabID = state.tabManager.createTab(title: "other", icon: nil)
      state.tabManager.selectTab(tabID)
    }
  }

  private func preparePoll(
    _ fixture: DetectionFixture,
    previous: PaneAgentState,
    detected: AgentRawState
  ) {
    fixture.state.surfaceAgentStates[fixture.surface.id] = previous
    fixture.state.agentDetectionPresenceBySurface[fixture.surface.id] = AgentDetectionPresence(
      currentAgent: .claude
    )
    prepareDetection(fixture, detected: detected)
  }

  private func prepareDetection(_ fixture: DetectionFixture, detected: AgentRawState) {
    fixture.state.lastAgentScreenScanBySurface[fixture.surface.id] = WorktreeTerminalState.AgentScreenScan(
      agent: .claude,
      text: "",
      detection: AgentScreenDetection(state: detected, reason: .legacyDetector)
    )
  }
}
