import Foundation
import Testing

@testable import supacode

/// Composition tests for the screen detection pipeline.
///
/// `ScreenHeuristicsTests` and the fixture corpus prove `screen -> AgentScreenDetection`,
/// and `AgentStateMachineTests` proves `event -> AgentStateDecision`, but each stage is
/// driven by a hand-built input of its own type, so nothing verifies that a screen reaches
/// the status the sidebar and `prowl list` report. These tests start from a screen and run
/// the stages production runs on each poll: the agent's screen profile,
/// `AgentDetectionCoordinator`, and `PaneAgentState`. Most cases take the screen path of a
/// pane with no process generation; one supplies a generation and native status through
/// the coordinator's provider sample.
@MainActor
struct AgentDetectionPipelineTests {
  private final class Clock {
    var now: TimeInterval = 100
  }

  private let clock: Clock
  private let coordinator: AgentDetectionCoordinator

  init() {
    let clock = Clock()
    self.clock = clock
    coordinator = AgentDetectionCoordinator(time: { clock.now })
  }

  /// Runs one captured screen through detection, coordination, and pane state, as
  /// `WorktreeTerminalState` does on each poll.
  private func report(
    _ screen: String,
    agent: DetectedAgent = .claude,
    through coordinator: AgentDetectionCoordinator? = nil,
    process: AgentProcessGeneration? = nil
  ) async -> PaneAgentState? {
    let detection = agent.detectScreen(in: screen)
    let decision = await (coordinator ?? self.coordinator).observe(
      agent: agent,
      process: process,
      screen: detection,
      screenContentID: detection.state == .blocked ? screen.hashValue : nil,
      capturedAt: clock.now,
      configRoot: nil
    )
    guard let decision else { return nil }
    return PaneAgentState(detectedAgent: agent, fallbackState: detection.state, state: decision.state)
  }

  @Test func longRunningTurnIsReportedBusyEndToEnd() async throws {
    // Claude Code 2.1.220: a turn past the minute mark shows a compound elapsed counter.
    let screen = """
      ⏺ Update(docs/guide.md)
        ⎿  Updated docs/guide.md with 12 additions

      ● Actioning… (28m 34s · ↓ 47.7k tokens)
      ─────────
      ❯
      ─────────
        ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents
      """

    let pane = try #require(await report(screen))
    #expect(pane.fallbackState == .working)
    #expect(pane.displayState == .working)
    #expect(pane.isBusy)
  }

  /// Claude Code 2.1.220: the main turn has finished while background agents still run,
  /// so the only live signal is the agent switcher below the composer.
  private static let backgroundAgentsScreen = """
    ⏺ Waiting for the background agents to report.

    ✻ Waiting for 2 background agents to finish
    ─────────
    ❯
    ─────────
      [Opus 5 (1M context)] | ############--------  60% | $XX.XX
      🟢
      ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents

      ⏺ main
      ◯ Explore  Survey the parser                1m 6s · ↓ 28.6k tokens
      ◯ general-purpose  Review the tests         4m 29s · ↓ 178.9k tokens
    """

  /// The same pane after every background agent has finished: the switcher is gone.
  private static let finishedScreen = """
    ⏺ All three agents returned.

    ─────────
    ❯
    ─────────
      [Opus 5 (1M context)] | --------------------  0% | $XX.XX
      🟢
      ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents
    """

  @Test func liveBackgroundAgentsAreReportedBusyEndToEnd() async throws {
    let pane = try #require(await report(Self.backgroundAgentsScreen))
    #expect(pane.fallbackState == .working)
    #expect(pane.displayState == .working)
    #expect(pane.isBusy)
  }

  @Test func finishedBackgroundAgentsReleaseTheBusyPane() async throws {
    // Negative control for the two tests above, through one coordinator: the pane that
    // was busy on the switcher must stop being busy once the switcher is gone.
    let busy = try #require(await report(Self.backgroundAgentsScreen))
    #expect(busy.isBusy)

    clock.now += 5
    let pane = try #require(await report(Self.finishedScreen))
    #expect(pane.fallbackState == .idle)
    #expect(pane.state == .idle)
    #expect(pane.displayState == .idle)
    #expect(!pane.isBusy)
  }

  @Test func nativeStatusDecidesALivePaneOverItsScreen() async throws {
    // A live pane has a process generation, so after the screen the coordinator samples
    // the Claude runtime provider. While native status is available it decides the state:
    // each step pairs native status with a screen that reads the opposite way.
    final class Native {
      var state: AgentRawState = .working
      var updatedAt: TimeInterval = 1
    }
    let native = Native()
    let clock = clock
    let live = AgentDetectionCoordinator(
      sample: { _, _ in
        [.native(AgentNativeSnapshot(sessionID: "session", state: native.state, statusUpdatedAt: native.updatedAt))]
      },
      time: { clock.now }
    )
    let generation = AgentProcessGeneration(pid: 42, startedAt: Date(timeIntervalSince1970: 1))

    let working = try #require(await report(Self.finishedScreen, through: live, process: generation))
    #expect(working.fallbackState == .idle)
    #expect(working.displayState == .working)
    #expect(working.isBusy)

    native.state = .idle
    native.updatedAt = 2
    clock.now += 1
    let idle = try #require(await report(Self.backgroundAgentsScreen, through: live, process: generation))
    #expect(idle.fallbackState == .working)
    #expect(idle.displayState == .idle)
    #expect(!idle.isBusy)
  }

  @Test func blockedPromptReplacesAWorkingTurnAtOnce() async throws {
    let working = """
      ● Running the test suite… (2m 28s · ↓ 13.2k tokens)
      ─────────
      ❯
      ─────────
      """
    let prompt = """
      Do you want to proceed?
      ❯ 1. Yes
        2. No
      Esc to cancel · Tab to amend
      """

    let before = try #require(await report(working))
    #expect(before.displayState == .working)

    clock.now += 0.5
    let pane = try #require(await report(prompt))
    #expect(pane.fallbackState == .blocked)
    #expect(pane.displayState == .blocked)
    #expect(pane.isBusy)
  }

  @Test func transcriptViewerKeepsALongTurnBusy() async throws {
    // Opening the transcript viewer mid-turn hides the live status area, so the screen
    // classifies as unknown. The pane keeps its last classified state until the screen
    // classifies again.
    let viewer = try String(
      contentsOf: AgentScreenFixtureCorpus.root.appending(path: "claude/2.1.270/unknown/scrolled-transcript.txt"),
      encoding: .utf8
    )
    let working = """
      ● Running the test suite… (2m 28s · ↓ 13.2k tokens)
      ─────────
      ❯
      ─────────
      """

    let before = try #require(await report(working))
    #expect(before.displayState == .working)

    clock.now += 2
    let pane = try #require(await report(viewer))
    #expect(pane.fallbackState == .unknown)
    #expect(pane.displayState == .working)
    #expect(pane.isBusy)
  }
}
