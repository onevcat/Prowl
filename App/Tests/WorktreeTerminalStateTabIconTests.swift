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

  // MARK: - Agent exit

  private func job(_ name: String, pid: pid_t = getpid()) -> ForegroundJob {
    ForegroundJob(
      processGroupID: pid,
      processes: [
        ForegroundProcess(pid: pid, parentProcessID: getppid(), name: name, argv0: name, cmdline: name)
      ])
  }

  /// A real process outside the test host's tree (double fork), so the launcher
  /// ancestry check sees a different launch.
  private func spawnDetachedSleeper() throws -> pid_t {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    let text = try #require(String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
    return try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  /// A pane where a real detection tick has bound `claude`.
  private func makeDetectedClaude() async throws -> (fixture: Fixture, surface: GhosttySurfaceView) {
    let fixture = try makeFixture()
    let state = fixture.state
    let surface = try #require(state.surfaceView(for: fixture.surfaceID))
    let claudeJob = job("claude")
    state.agentProcessProbeForTesting = { _, _, _ in claudeJob }
    state.programStatusSupportForTesting = { _ in .verified }
    state.agentDetectionTasks[fixture.surfaceID] = Task {}
    state.surfaceAgentStates[fixture.surfaceID] = PaneAgentState(lastChangedAt: Date())
    seedScreenScan(.claude, fixture)
    #expect(await detect(fixture, surface))
    #expect(state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
    #expect(fixture.icon == claudeIcon)
    return (fixture, surface)
  }

  private func seedScreenScan(_ agent: DetectedAgent, _ fixture: Fixture) {
    fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID] = WorktreeTerminalState.AgentScreenScan(
      agent: agent, text: "", detection: AgentScreenDetection(state: .idle, reason: .legacyDetector))
  }

  @discardableResult
  private func detect(_ fixture: Fixture, _ surface: GhosttySurfaceView) async -> Bool {
    await fixture.state.detectAgentState(
      for: surface, tabId: fixture.tabID,
      resolveSession: { _, _, _, _, _ in (nil, 0) })
  }

  /// Reports `command_finished`, then runs the fresh probe it requests. `whileProbing`
  /// runs while that probe is suspended and the previous agent is still recorded.
  private func finishCommand(
    _ fixture: Fixture,
    _ surface: GhosttySurfaceView,
    probeFinds found: ForegroundJob?,
    whileProbing: @escaping @MainActor () -> Void
  ) async {
    fixture.state.agentProcessProbeForTesting = { _, _, fresh in
      if fresh { whileProbing() }
      return found
    }
    fixture.state.handleCommandFinished(exitCode: 0, durationNs: 0, surfaceId: fixture.surfaceID)
    await detect(fixture, surface)
  }

  @Test func commandTitleDuringTheExitProbeBrandsTheTabOnceTheAgentIsReleased() async throws {
    let (fixture, surface) = try await makeDetectedClaude()

    await finishCommand(fixture, surface, probeFinds: nil) {
      fixture.noteTitle("my prompt")
      fixture.noteTitle("git status")
      #expect(fixture.icon == claudeIcon)
    }

    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)
    #expect(fixture.icon == gitIcon)
  }

  /// The prompt of a shell nested in the agent also reports `command_finished`.
  @Test func commandTitleDuringTheProbeIsDiscardedWhenTheAgentIsStillRunning() async throws {
    let (fixture, surface) = try await makeDetectedClaude()

    await finishCommand(fixture, surface, probeFinds: job("claude")) {
      fixture.noteTitle("my prompt")
      fixture.noteTitle("git status")
    }
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
    #expect(fixture.icon == claudeIcon)

    // The discarded title does not come back when this agent exits later.
    await finishCommand(fixture, surface, probeFinds: nil) {}
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)
    #expect(fixture.icon == claudeIcon)
  }

  @Test func successorAgentBrandsTheTabInsteadOfTheCommandTitle() async throws {
    let (fixture, surface) = try await makeDetectedClaude()
    seedScreenScan(.codex, fixture)
    let successor = try spawnDetachedSleeper()
    defer { kill(successor, SIGTERM) }

    await finishCommand(fixture, surface, probeFinds: job("codex", pid: successor)) {
      fixture.noteTitle("my prompt")
      fixture.noteTitle("git status")
    }

    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .codex)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == .local(successor))
    #expect(fixture.icon == codexIcon)

    // The discarded title does not come back when the successor exits.
    await finishCommand(fixture, surface, probeFinds: nil) {}
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)
    #expect(fixture.icon == codexIcon)
  }

  /// A topic title that precedes `command_finished` came from the agent, not the shell.
  @Test func topicTitleBeforeTheExitIsNotAppliedAfterTheRelease() async throws {
    let (fixture, surface) = try await makeDetectedClaude()
    fixture.noteTitle("Codex thread demo")

    await finishCommand(fixture, surface, probeFinds: nil) {
      fixture.noteTitle("my prompt")
    }

    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)
    #expect(fixture.icon == claudeIcon)
  }

  @Test func commandTitleDuringTheExitProbeKeepsAUserIcon() async throws {
    let (fixture, surface) = try await makeDetectedClaude()
    fixture.state.tabManager.overrideIcon(fixture.tabID, icon: codexIcon)

    await finishCommand(fixture, surface, probeFinds: nil) {
      fixture.noteTitle("my prompt")
      fixture.noteTitle("git status")
    }

    #expect(fixture.icon == codexIcon)
  }

  @Test func commandTitleDuringTheExitProbeDoesNotBrandAfterFocusMoved() async throws {
    let (fixture, surface) = try await makeDetectedClaude()
    let rightID = try fixture.state.createSplit(
      of: fixture.surfaceID, direction: .right, initialInput: nil, focusing: false
    ).get()
    let right = try #require(fixture.state.surfaceView(for: rightID))

    await finishCommand(fixture, surface, probeFinds: nil) {
      fixture.noteTitle("my prompt")
      fixture.noteTitle("git status")
      fixture.state.recordActiveSurface(right, in: fixture.tabID)
    }

    #expect(fixture.icon == claudeIcon)
  }

  /// Detection can release the pane before the fresh probe reports. A newer command
  /// has then set the icon already, and the older title must not replace it.
  @Test func newerCommandWinsOverAnOlderTitleFromTheExitProbe() async throws {
    let (fixture, surface) = try await makeDetectedClaude()

    await finishCommand(fixture, surface, probeFinds: nil) {
      fixture.noteTitle("my prompt")
      fixture.noteTitle("git status")
      fixture.state.surfaceAgentStates[fixture.surfaceID] = PaneAgentState()
      fixture.noteTitle("codex --full-auto")
    }

    #expect(fixture.icon == codexIcon)
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

  // MARK: - Focus

  /// A tab with the fixture's focused pane on the left and an unfocused pane on the right.
  private func makeSplit(_ fixture: Fixture) throws -> GhosttySurfaceView {
    let rightID = try fixture.state.createSplit(
      of: fixture.surfaceID, direction: .right, initialInput: nil, focusing: false
    ).get()
    #expect(fixture.state.focusedSurfaceId(in: fixture.tabID) == fixture.surfaceID)
    return try #require(fixture.state.surfaceView(for: rightID))
  }

  private func detectClaude(in surfaceID: UUID, _ fixture: Fixture, token: String = "claude") {
    fixture.state.commitAgentState(
      PaneAgentState(detectedAgent: .claude, iconLookupToken: token, state: .idle),
      previous: PaneAgentState(),
      surfaceID: surfaceID,
      tabId: fixture.tabID)
  }

  @Test func focusingAnAgentPaneTakesItsIcon() throws {
    let fixture = try makeFixture()
    let right = try makeSplit(fixture)
    detectClaude(in: right.id, fixture)
    #expect(fixture.icon != claudeIcon)

    fixture.state.recordActiveSurface(right, in: fixture.tabID)

    #expect(fixture.icon == claudeIcon)
  }

  @Test func focusUsesTheProcessNameBeforeTheAgent() throws {
    let fixture = try makeFixture()
    let right = try makeSplit(fixture)
    detectClaude(in: right.id, fixture, token: "omp")

    fixture.state.recordActiveSurface(right, in: fixture.tabID)

    #expect(fixture.icon == "@asset:OMP")
  }

  /// A plain pane has no record of its current command, so focus leaves the icon alone,
  /// and the next command in that pane decides.
  @Test func focusingAPlainPaneKeepsTheIconUntilItsNextCommand() throws {
    let fixture = try makeFixture()
    let right = try makeSplit(fixture)
    detectClaude(in: fixture.surfaceID, fixture)
    #expect(fixture.icon == claudeIcon)

    fixture.state.recordActiveSurface(right, in: fixture.tabID)
    #expect(fixture.icon == claudeIcon)

    fixture.state.noteTitleForCommandDetection("git status", surfaceId: right.id, tabId: fixture.tabID)
    #expect(fixture.icon == gitIcon)
  }

  @Test func focusMovesTheIconBackToTheAgentPane() throws {
    let fixture = try makeFixture()
    let right = try makeSplit(fixture)
    let left = try #require(fixture.state.surfaceView(for: fixture.surfaceID))
    detectClaude(in: fixture.surfaceID, fixture)
    fixture.state.recordActiveSurface(right, in: fixture.tabID)
    fixture.state.noteTitleForCommandDetection("git status", surfaceId: right.id, tabId: fixture.tabID)
    #expect(fixture.icon == gitIcon)

    fixture.state.recordActiveSurface(left, in: fixture.tabID)

    #expect(fixture.icon == claudeIcon)
  }

  @Test func focusFollowsTheAgentOfEachPane() throws {
    let fixture = try makeFixture()
    let right = try makeSplit(fixture)
    let left = try #require(fixture.state.surfaceView(for: fixture.surfaceID))
    detectClaude(in: fixture.surfaceID, fixture)
    fixture.state.commitAgentState(
      PaneAgentState(detectedAgent: .codex, iconLookupToken: "codex", state: .idle),
      previous: PaneAgentState(),
      surfaceID: right.id,
      tabId: fixture.tabID)

    fixture.state.recordActiveSurface(right, in: fixture.tabID)
    #expect(fixture.icon == codexIcon)

    fixture.state.recordActiveSurface(left, in: fixture.tabID)
    #expect(fixture.icon == claudeIcon)
  }

  @Test func focusKeepsAUserIcon() throws {
    let fixture = try makeFixture()
    let right = try makeSplit(fixture)
    detectClaude(in: right.id, fixture)
    fixture.state.tabManager.overrideIcon(fixture.tabID, icon: gitIcon)

    fixture.state.recordActiveSurface(right, in: fixture.tabID)

    #expect(fixture.icon == gitIcon)
  }

  @Test func focusKeepsAScriptIcon() throws {
    let fixture = try makeFixture()
    let right = try makeSplit(fixture)
    detectClaude(in: right.id, fixture)
    fixture.state.tabManager.setScriptIcon(fixture.tabID, icon: gitIcon)

    fixture.state.recordActiveSurface(right, in: fixture.tabID)

    #expect(fixture.icon == gitIcon)
  }

  /// The production callback: Ghostty reports focus through the surface bridge.
  @Test func surfaceFocusCallbackTakesTheAgentIcon() throws {
    let fixture = try makeFixture()
    let right = try makeSplit(fixture)
    detectClaude(in: right.id, fixture)
    fixture.state.configureSurfaceCallbacks(for: right, tabId: fixture.tabID)

    right.onFocusChange?(true)

    #expect(fixture.icon == claudeIcon)
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
