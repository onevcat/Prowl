import Foundation
import Testing

@testable import Prowl

/// An agent's OSC 2 title is its conversation topic, not a command line, so only the
/// detected identity may brand a pane's tab while the agent runs (issue #1015).
@MainActor
struct WorktreeTerminalStateTabIconTests {
  private let codexIcon = "@asset:Codex"
  private let claudeIcon = "@asset:ClaudeCode"
  private let gitIcon = "@asset:Git"

  private struct Fixture {
    let manager: WorktreeTerminalManager
    let state: WorktreeTerminalState
    let tabID: TerminalTabID
    let surfaceID: UUID

    var icon: String? { state.tabManager.tabs.first { $0.id == tabID }?.icon }

    func noteTitle(_ title: String) {
      state.noteTitleForCommandDetection(title, surfaceId: surfaceID, tabId: tabID)
    }

    /// Mirrors the first commit of a detected agent, as `detectAgentState` does it.
    func commit(_ next: PaneAgentState) {
      let previous = state.surfaceAgentStates[surfaceID] ?? PaneAgentState()
      state.commitAgentState(next, previous: previous, surfaceID: surfaceID, tabId: tabID)
    }
  }

  private func makeFixture() throws -> Fixture {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime(), skipsSurfaceCreationForTesting: true)
    let worktree = Worktree(
      id: "/tmp/repo/wt-1", name: "wt-1", detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"), repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"))
    let state = manager.state(for: worktree)
    let tabID = try #require(state.createTab())
    let surfaceID = try #require(state.focusedSurfaceId(in: tabID))
    return Fixture(manager: manager, state: state, tabID: tabID, surfaceID: surfaceID)
  }

  // MARK: - Titles

  @Test func shellTitleStillBrandsAPaneWithoutAnAgent() throws {
    let fixture = try makeFixture()
    fixture.noteTitle("codex --full-auto")
    #expect(fixture.icon == codexIcon)
  }

  @Test func detectedAgentsTopicTitleDoesNotBrandTheTab() throws {
    let fixture = try makeFixture()
    fixture.commit(PaneAgentState(detectedAgent: .claude, iconLookupToken: "claude", state: .idle))
    #expect(fixture.icon == claudeIcon)

    for topic in ["Codex thread demo", "Code review notes", "Git history cleanup", "Language Models Need Sleep"] {
      fixture.noteTitle(topic)
      #expect(fixture.icon == claudeIcon, "\(topic) took the tab icon")
    }
  }

  @Test func shellTitleTakesOverAgainAfterTheAgentExits() throws {
    let fixture = try makeFixture()
    fixture.commit(PaneAgentState(detectedAgent: .claude, iconLookupToken: "claude", state: .idle))
    fixture.noteTitle("Codex thread demo")

    fixture.state.surfaceAgentStates[fixture.surfaceID] = PaneAgentState()
    fixture.noteTitle("git status")

    #expect(fixture.icon == gitIcon)
  }

  /// The agent's exit reports `command_finished` before detection releases the pane.
  /// The prompt title that follows must still reach the idle learner, or the learner
  /// stays armed and takes the user's next command for a prompt.
  @Test func promptTitleIsLearnedWhileTheExitedAgentIsStillDetected() throws {
    let fixture = try makeFixture()
    fixture.commit(PaneAgentState(detectedAgent: .claude, iconLookupToken: "claude", state: .idle))

    fixture.state.noteCommandFinishedForCommandDetection(surfaceId: fixture.surfaceID)
    fixture.noteTitle("my prompt")
    fixture.state.surfaceAgentStates[fixture.surfaceID] = PaneAgentState()
    fixture.noteTitle("git status")

    #expect(fixture.icon == gitIcon)
    #expect(fixture.state.learnedIdleTitlesBySurface[fixture.surfaceID] == ["my prompt"])
  }

  // MARK: - Detection

  @Test func detectionReplacesAWrongTitleIcon() throws {
    let fixture = try makeFixture()
    fixture.noteTitle("Codex thread demo")
    #expect(fixture.icon == codexIcon)

    fixture.commit(PaneAgentState(detectedAgent: .claude, iconLookupToken: "claude", state: .idle))

    #expect(fixture.icon == claudeIcon)
  }

  /// `alias ccr='claude --resume'` leaves a shell title the map does not know.
  @Test func detectionBrandsAnAgentStartedThroughAnAlias() throws {
    let fixture = try makeFixture()
    fixture.noteTitle("ccr")
    let original = fixture.icon

    fixture.commit(PaneAgentState(detectedAgent: .claude, iconLookupToken: "claude", state: .idle))

    #expect(fixture.icon != original)
    #expect(fixture.icon == claudeIcon)
  }

  @Test func detectionFallsBackToTheAgentWhenTheProcessNameHasNoIcon() throws {
    let fixture = try makeFixture()
    fixture.commit(PaneAgentState(detectedAgent: .claude, iconLookupToken: "claude-wrapper", state: .idle))
    #expect(fixture.icon == claudeIcon)
  }

  @Test func detectionUsesTheProcessNameBeforeTheAgent() throws {
    let fixture = try makeFixture()
    fixture.commit(PaneAgentState(detectedAgent: .pi, iconLookupToken: "omp", state: .idle))
    #expect(fixture.icon == "@asset:OMP")
  }

  @Test func stateChangesOfTheSameAgentDoNotBrandTheTabAgain() throws {
    let fixture = try makeFixture()
    fixture.commit(PaneAgentState(detectedAgent: .claude, iconLookupToken: "claude", state: .idle))
    fixture.state.tabManager.updateIcon(fixture.tabID, icon: gitIcon)

    fixture.commit(PaneAgentState(detectedAgent: .claude, iconLookupToken: "claude", state: .working))

    #expect(fixture.icon == gitIcon)
  }

  @Test func detectionKeepsAUserIcon() throws {
    let fixture = try makeFixture()
    fixture.state.tabManager.overrideIcon(fixture.tabID, icon: gitIcon)

    fixture.commit(PaneAgentState(detectedAgent: .claude, iconLookupToken: "claude", state: .idle))

    #expect(fixture.icon == gitIcon)
  }

  @Test func detectionKeepsAScriptIcon() throws {
    let fixture = try makeFixture()
    fixture.state.tabManager.setScriptIcon(fixture.tabID, icon: gitIcon)

    fixture.commit(PaneAgentState(detectedAgent: .claude, iconLookupToken: "claude", state: .idle))

    #expect(fixture.icon == gitIcon)
  }

  @Test func detectionInAnUnfocusedSplitDoesNotBrandTheTab() throws {
    let fixture = try makeFixture()
    fixture.noteTitle("git status")
    let unfocusedID = UUID()

    fixture.state.commitAgentState(
      PaneAgentState(detectedAgent: .claude, iconLookupToken: "claude", state: .idle),
      previous: PaneAgentState(),
      surfaceID: unfocusedID,
      tabId: fixture.tabID)

    #expect(fixture.icon == gitIcon)
  }

  /// The production path: a probe binds `claude` and `detectAgentState` commits it.
  @Test func detectionTickCorrectsTheIcon() async throws {
    let fixture = try makeFixture()
    let state = fixture.state
    let surface = try #require(state.surfaceView(for: fixture.surfaceID))
    let job = ForegroundJob(
      processGroupID: getpid(),
      processes: [
        ForegroundProcess(pid: getpid(), parentProcessID: getppid(), name: "claude", argv0: "claude", cmdline: "claude")
      ])
    state.agentProcessProbeForTesting = { _, _, _ in job }
    state.programStatusSupportForTesting = { _ in .verified }
    state.agentDetectionTasks[fixture.surfaceID] = Task {}
    state.surfaceAgentStates[fixture.surfaceID] = PaneAgentState(lastChangedAt: Date())
    state.lastAgentScreenScanBySurface[fixture.surfaceID] = WorktreeTerminalState.AgentScreenScan(
      agent: .claude, text: "", detection: AgentScreenDetection(state: .idle, reason: .legacyDetector))
    fixture.noteTitle("Codex thread demo")
    #expect(fixture.icon == codexIcon)

    #expect(
      await state.detectAgentState(
        for: surface, tabId: fixture.tabID,
        resolveSession: { _, _, _, _, _ in (nil, 0) }))

    #expect(state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
    #expect(fixture.icon == claudeIcon)

    fixture.noteTitle("Codex thread review")
    #expect(fixture.icon == claudeIcon)
  }
}
