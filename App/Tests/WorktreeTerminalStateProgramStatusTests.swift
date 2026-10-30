import Foundation
import GhosttyKit
import Testing

@testable import Prowl

/// The terminal owner's half of OSC 7501 (docs-ai 079 slice 2): the record store per
/// surface, the push path through `publishDecision`, the interruptible detection loop,
/// the delegated tick, the command-finished release, and the undo-close feed. The
/// process probe is replaced by a fake foreground job built around this test process so
/// the generation fence sees a real start time.
@MainActor
@Suite(.serialized)
struct WorktreeTerminalStateProgramStatusTests {
  private struct Fixture {
    let state: WorktreeTerminalState
    let tabID: TerminalTabID
    let surface: GhosttySurfaceView
    var surfaceID: UUID { surface.id }
  }

  private final class Probe {
    var job: ForegroundJob?
    var calls: [Bool] = []
    /// When set, the next probe call suspends here until resumed.
    var gate: CheckedContinuation<Void, Never>?
    var entered: AsyncStream<Void>.Continuation?
  }

  private let epoch = Date(timeIntervalSince1970: 1_000)

  /// A second real process (its start time is readable, unlike launchd's, which is
  /// the test host's parent) to stand in for an engine child or a successor launch.
  private func spawnSleeper() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    return process
  }

  /// A real process that is not a descendant of the test host (double fork), so the
  /// launcher-ancestry check sees a genuinely different launch.
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

  private func claudeJob(pid: pid_t) -> ForegroundJob {
    ForegroundJob(
      processGroupID: pid,
      processes: [ForegroundProcess(pid: pid, parentProcessID: 1, name: "claude", argv0: "claude", cmdline: "claude")])
  }

  private func report(
    _ state: GhosttyProgramStatusReport.State, id: String = "", app: String? = "claude-code",
    kind: GhosttyProgramStatusReport.Kind? = nil
  ) -> GhosttyProgramStatusReport {
    GhosttyProgramStatusReport(state: state, kind: kind, id: id, app: app)
  }

  /// A foreground job whose only member is this test process, named like the agent.
  private func claudeJob(launchPID: pid_t? = nil) -> ForegroundJob {
    let pid = getpid()
    var processes = [
      ForegroundProcess(
        pid: pid, parentProcessID: launchPID ?? getppid(), name: "claude", argv0: "claude", cmdline: "claude")
    ]
    if let launchPID {
      processes.insert(
        ForegroundProcess(pid: launchPID, parentProcessID: 1, name: "node", argv0: "node", cmdline: "node"), at: 0)
    }
    return ForegroundJob(processGroupID: pid, processes: processes)
  }

  /// `startsLoop: false` parks a placeholder task so a wake never starts the real
  /// detection loop; the tests drive `detectAgentState` themselves. `support: nil`
  /// keeps the production table (`ProgramStatusSupport.level(for:)`).
  private func makeFixture(
    support: ProgramStatusSupport? = .verified,
    probe: Probe,
    startsLoop: Bool = false
  ) -> Fixture {
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: Worktree(
        id: "/tmp/repo/worktree",
        name: "worktree",
        detail: "",
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/worktree"),
        repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
      ),
      skipsSurfaceCreationForTesting: true
    )
    state.programStatusSupportForTesting = support.map { level in { _ in level } }
    state.agentProcessProbeForTesting = { _, _, fresh in
      probe.calls.append(fresh)
      if let entered = probe.entered {
        probe.entered = nil
        await withCheckedContinuation { continuation in
          probe.gate = continuation
          entered.yield(())
        }
      }
      return probe.job
    }
    state.lastWindowIsKey = false
    state.lastWindowIsVisible = false
    let tabID = state.tabManager.createTab(title: "worktree 1", icon: "terminal")
    let surface = GhosttySurfaceView(
      runtime: state.runtime,
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/worktree", isDirectory: true),
      fontSize: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    state.configureBridgeCallbacks(for: surface, tabId: tabID)
    state.configureSurfaceCallbacks(for: surface, tabId: tabID)
    state.surfaces[surface.id] = surface
    state.trees[tabID] = SplitTree<GhosttySurfaceView>(view: surface)
    state.focusedSurfaceIdByTab[tabID] = surface.id
    // `wakeAgentDetection` seeds this before the loop's first poll in production.
    state.surfaceAgentStates[surface.id] = PaneAgentState(lastChangedAt: epoch)
    if !startsLoop {
      state.agentDetectionTasks[surface.id] = Task {}
    }
    return Fixture(state: state, tabID: tabID, surface: surface)
  }

  private func noSession(
    _: IdentifiedAgentProcess?, _: PaneAgentState, _: URL?, _: String, _: (surfaceID: UUID, configRoot: URL?)
  ) -> (session: AgentSession?, missStreak: Int) {
    (nil, 0)
  }

  /// One poll with the fake probe; seeds an idle screen scan so the legacy decision is definite.
  private func detect(_ fixture: Fixture, now: Date = Date()) async -> Bool {
    await fixture.state.detectAgentState(
      for: fixture.surface, tabId: fixture.tabID, resolveSession: noSession, now: now)
  }

  private func bind(_ fixture: Fixture, probe: Probe) async {
    probe.job = claudeJob()
    fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID] = WorktreeTerminalState.AgentScreenScan(
      agent: .claude, text: "", detection: AgentScreenDetection(state: .idle, reason: .legacyDetector))
    #expect(await detect(fixture))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
  }

  // MARK: Store ownership and the push path

  @Test func reportBeforeAnyAgentIsStoredAndWakesDetection() {
    let probe = Probe()
    let fixture = makeFixture(probe: probe, startsLoop: true)
    #expect(fixture.state.agentDetectionTasks[fixture.surfaceID] == nil)

    fixture.surface.bridge.onProgramStatus?(report(.idle, app: "pi"))

    #expect(fixture.state.programStatusStoresBySurface[fixture.surfaceID]?.root?.state == .idle)
    #expect(fixture.state.agentDetectionTasks[fixture.surfaceID] != nil)
    #expect(fixture.state.agentDetectionSchedules[fixture.surfaceID]?.nextInterval(now: Date()) != nil)
    fixture.state.cleanupAllAgentDetectionState()
  }

  @Test func verifiedPushPublishesInTheSameTurn() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var emitted: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { emitted.append($0) }
    await bind(fixture, probe: probe)
    emitted.removeAll()

    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)

    let pane = fixture.state.surfaceAgentStates[fixture.surfaceID]
    #expect(pane?.state == .working)
    #expect(pane?.decision?.reason.identifier == "osc.working")
    #expect(pane?.decision?.screenReason == .delegated)
    #expect(fixture.state.tabAgentBusyById[fixture.tabID] == true)
    #expect(emitted.map(\.displayState) == [.working])
    // Pid, session, and launch metadata are merged, not replaced.
    #expect(pane?.agentProcess == .local(getpid()))
  }

  @Test func doneAndErrorEarnTheBadgeButIdleDoesNot() async {
    for (state, badge) in [(GhosttyProgramStatusReport.State.done, true), (.error, true), (.idle, false)] {
      let probe = Probe()
      let fixture = makeFixture(probe: probe)
      await bind(fixture, probe: probe)
      fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)

      fixture.state.handleProgramStatus(report(state), surfaceID: fixture.surfaceID)

      let pane = fixture.state.surfaceAgentStates[fixture.surfaceID]
      #expect(pane?.state == .idle)
      #expect(pane?.displayState == (badge ? .done : .idle), "\(state)")
    }
  }

  @Test func unverifiedPushChangesNothingPublished() async {
    let probe = Probe()
    let fixture = makeFixture(support: .unverified, probe: probe)
    await bind(fixture, probe: probe)
    let before = fixture.state.surfaceAgentStates[fixture.surfaceID]

    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)

    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID] == before)
    #expect(fixture.state.programStatusStoresBySurface[fixture.surfaceID]?.root?.state == .working)
  }

  /// Verified roots decide the published state and delegate the schedule.
  @Test func productionTableVerifiesKnownProducers() async {
    let claudeProbe = Probe()
    let claude = makeFixture(support: nil, probe: claudeProbe)
    await bind(claude, probe: claudeProbe)

    claude.state.handleProgramStatus(report(.working), surfaceID: claude.surfaceID)

    let claudePane = claude.state.surfaceAgentStates[claude.surfaceID]
    #expect(claudePane?.state == .working)
    #expect(claudePane?.decision?.reason.identifier == "osc.working")
    #expect(claude.state.agentDetectionCoordinators[claude.surfaceID]?.isDelegated == true)
    #expect(claude.state.nextScheduleAfterTick(surfaceID: claude.surfaceID, hasAgent: true) == .delegated)

    let piProbe = Probe()
    let piFixture = makeFixture(support: nil, probe: piProbe)
    piProbe.job = ForegroundJob(
      processGroupID: getpid(),
      processes: [
        ForegroundProcess(pid: getpid(), parentProcessID: getppid(), name: "pi", argv0: "pi", cmdline: "pi")
      ])
    piFixture.state.lastAgentScreenScanBySurface[piFixture.surfaceID] = WorktreeTerminalState.AgentScreenScan(
      agent: .pi, text: "", detection: AgentScreenDetection(state: .idle, reason: .legacyDetector))
    #expect(await detect(piFixture))
    #expect(piFixture.state.surfaceAgentStates[piFixture.surfaceID]?.detectedAgent == .pi)

    piFixture.state.handleProgramStatus(report(.working, app: "pi"), surfaceID: piFixture.surfaceID)

    let piPane = piFixture.state.surfaceAgentStates[piFixture.surfaceID]
    #expect(piPane?.state == .working)
    #expect(piPane?.decision?.reason.identifier == "osc.working")
    #expect(piFixture.state.agentDetectionCoordinators[piFixture.surfaceID]?.isDelegated == true)
    #expect(piFixture.state.nextScheduleAfterTick(surfaceID: piFixture.surfaceID, hasAgent: true) == .delegated)

    let ompProbe = Probe()
    let ompFixture = makeFixture(support: nil, probe: ompProbe)
    ompProbe.job = ForegroundJob(
      processGroupID: getpid(),
      processes: [
        ForegroundProcess(pid: getpid(), parentProcessID: getppid(), name: "omp", argv0: "omp", cmdline: "omp")
      ])
    ompFixture.state.lastAgentScreenScanBySurface[ompFixture.surfaceID] = WorktreeTerminalState.AgentScreenScan(
      agent: .omp, text: "", detection: AgentScreenDetection(state: .idle, reason: .legacyDetector))
    #expect(await detect(ompFixture))
    #expect(ompFixture.state.surfaceAgentStates[ompFixture.surfaceID]?.detectedAgent == .omp)

    ompFixture.state.handleProgramStatus(report(.working, app: "omp"), surfaceID: ompFixture.surfaceID)

    let ompPane = ompFixture.state.surfaceAgentStates[ompFixture.surfaceID]
    #expect(ompPane?.state == .working)
    #expect(ompPane?.decision?.reason.identifier == "osc.working")
    #expect(ompFixture.state.agentDetectionCoordinators[ompFixture.surfaceID]?.isDelegated == true)
    #expect(ompFixture.state.nextScheduleAfterTick(surfaceID: ompFixture.surfaceID, hasAgent: true) == .delegated)

    let codexProbe = Probe()
    let codex = makeFixture(support: nil, probe: codexProbe)
    codexProbe.job = ForegroundJob(
      processGroupID: getpid(),
      processes: [
        ForegroundProcess(pid: getpid(), parentProcessID: getppid(), name: "codex", argv0: "codex", cmdline: "codex")
      ])
    codex.state.lastAgentScreenScanBySurface[codex.surfaceID] = WorktreeTerminalState.AgentScreenScan(
      agent: .codex, text: "", detection: AgentScreenDetection(state: .idle, reason: .legacyDetector))
    #expect(await detect(codex))
    #expect(codex.state.surfaceAgentStates[codex.surfaceID]?.detectedAgent == .codex)

    codex.state.handleProgramStatus(report(.working, app: "codex"), surfaceID: codex.surfaceID)

    #expect(codex.state.surfaceAgentStates[codex.surfaceID]?.decision?.reason.identifier == "osc.working")
    #expect(codex.state.agentDetectionCoordinators[codex.surfaceID]?.isDelegated == true)
    #expect(codex.state.nextScheduleAfterTick(surfaceID: codex.surfaceID, hasAgent: true) == .delegated)

    codex.state.handleProgramStatus(report(.blocked, app: "codex"), surfaceID: codex.surfaceID)
    #expect(codex.state.surfaceAgentStates[codex.surfaceID]?.state == .blocked)
    #expect(
      codex.state.surfaceAgentStates[codex.surfaceID]?.decision?.reason.identifier == "osc.blocked.unspecified")
    codex.state.handleProgramStatus(report(.idle, app: "codex"), surfaceID: codex.surfaceID)
    #expect(codex.state.surfaceAgentStates[codex.surfaceID]?.displayState == .idle)
  }

  @Test(arguments: [
    (DetectedAgent.amp, "amp", "amp"),
    (.antigravity, "agy", "antigravity"),
    (.devin, "devin", "devin"),
    (.droid, "droid", "droid"),
    (.grok, "grok", "grok-build"),
  ])
  func productionTableVerifiesScreenOnlyProducer(agent: DetectedAgent, executable: String, app: String) async {
    let probe = Probe()
    let fixture = makeFixture(support: nil, probe: probe)
    probe.job = ForegroundJob(
      processGroupID: getpid(),
      processes: [
        ForegroundProcess(
          pid: getpid(), parentProcessID: getppid(), name: executable, argv0: executable, cmdline: executable)
      ])
    fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID] = WorktreeTerminalState.AgentScreenScan(
      agent: agent, text: "", detection: AgentScreenDetection(state: .idle, reason: .legacyDetector))
    #expect(await detect(fixture))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == agent)

    fixture.state.handleProgramStatus(report(.working, app: app), surfaceID: fixture.surfaceID)

    let pane = fixture.state.surfaceAgentStates[fixture.surfaceID]
    #expect(pane?.state == .working)
    #expect(pane?.decision?.reason.identifier == "osc.working")
    #expect(fixture.state.agentDetectionCoordinators[fixture.surfaceID]?.isDelegated == true)
    #expect(fixture.state.nextScheduleAfterTick(surfaceID: fixture.surfaceID, hasAgent: true) == .delegated)

    fixture.state.handleProgramStatus(report(.blocked, app: app, kind: .permission), surfaceID: fixture.surfaceID)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .blocked)
    #expect(
      fixture.state.surfaceAgentStates[fixture.surfaceID]?.decision?.reason.identifier == "osc.blocked.permission")
  }

  @Test func withdrawalPublishesNothingUntilAnObserveThatStartedAfterIt() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await bind(fixture, probe: probe)
    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)

    fixture.state.handleProgramStatus(report(.clear), surfaceID: fixture.surfaceID)

    // The pane still shows the last published decision; the probe was woken instead.
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.decision?.reason.identifier == "osc.working")
    #expect(fixture.state.agentDetectionCoordinators[fixture.surfaceID]?.decision?.reason.isProgramStatus == false)
    #expect(fixture.state.agentDetectionWakeRequests.contains(fixture.surfaceID))

    #expect(await detect(fixture))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.decision?.reason.isProgramStatus == false)
  }

  private let seededScan = WorktreeTerminalState.AgentScreenScan(
    agent: .claude, text: "seeded frame", detection: AgentScreenDetection(state: .idle, reason: .legacyDetector))

  /// Binds, takes OSC authority, and puts the loop on the delegated schedule as the
  /// loop's tick would have.
  private func delegate(_ fixture: Fixture, probe: Probe) async {
    await bind(fixture, probe: probe)
    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)
    #expect(fixture.state.agentDetectionCoordinators[fixture.surfaceID]?.isDelegated == true)
    fixture.state.agentDetectionSchedules[fixture.surfaceID] = .delegated
    fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID] = seededScan
  }

  @Test func delegatedTickSkipsTheScreenRead() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await delegate(fixture, probe: probe)

    #expect(await detect(fixture))

    // An active tick would have replaced the memo with the (empty) live frame.
    #expect(fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID] == seededScan)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.decision?.reason.identifier == "osc.working")
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.fallbackState == .idle)
    #expect(fixture.state.nextScheduleAfterTick(surfaceID: fixture.surfaceID, hasAgent: true) == .delegated)
  }

  @Test func keyPressKeepsTheActiveCadenceForTheSettleWindow() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await delegate(fixture, probe: probe)

    let pressedAt = Date()
    fixture.state.wakeAgentDetection(for: fixture.surface, tabId: fixture.tabID, now: pressedAt)
    #expect(fixture.state.agentDetectionSchedules[fixture.surfaceID] == .active)
    #expect(await detect(fixture, now: pressedAt))

    // The screen was read again (the memo now holds the live frame) and the decision
    // still follows the root record.
    #expect(fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID]?.text == "")
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.decision?.reason.identifier == "osc.working")

    // The one full tick is consumed, but the settle window keeps the active cadence: a
    // tick inside it reads the screen even on the delegated schedule, so a session the
    // key press switched (`/new`, `/resume`) is attributed from a settled frame.
    let inside = pressedAt.addingTimeInterval(AgentDetectionSchedule.settleWindow - 0.5)
    #expect(fixture.state.nextScheduleAfterTick(surfaceID: fixture.surfaceID, hasAgent: true, now: inside) == .active)
    fixture.state.agentDetectionSchedules[fixture.surfaceID] = .delegated
    fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID] = seededScan
    #expect(await detect(fixture, now: inside))
    #expect(fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID]?.text == "")

    // After the window the tick delegates again and leaves the memo alone.
    let settled = pressedAt.addingTimeInterval(AgentDetectionSchedule.settleWindow + 0.5)
    #expect(
      fixture.state.nextScheduleAfterTick(surfaceID: fixture.surfaceID, hasAgent: true, now: settled) == .delegated)
    fixture.state.agentDetectionSchedules[fixture.surfaceID] = .delegated
    fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID] = seededScan
    #expect(await detect(fixture, now: settled))
    #expect(fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID] == seededScan)
    #expect(fixture.state.agentDetectionSettleUntilBySurface[fixture.surfaceID] == nil)
  }

  @Test func keyPressDuringADelegatedTicksSuspensionStillGetsItsFullTick() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await delegate(fixture, probe: probe)
    fixture.state.agentDetectionFullTickRequests.remove(fixture.surfaceID)
    // Suspend the delegated tick inside the session resolver, after it chose to skip
    // the screen; a key press lands while it is suspended.
    let gate = AsyncStream<CheckedContinuation<Void, Never>>.makeStream()
    let tick = Task {
      await fixture.state.detectAgentState(
        for: fixture.surface, tabId: fixture.tabID,
        resolveSession: { _, _, _, _, _ in
          await withCheckedContinuation { gate.continuation.yield($0) }
          return (nil, 0)
        })
    }
    var iterator = gate.stream.makeAsyncIterator()
    let resume = await iterator.next()
    fixture.state.wakeAgentDetection(for: fixture.surface, tabId: fixture.tabID)
    resume?.resume()
    #expect(await tick.value)

    // That tick stayed delegated, so the request is still open: the loop stays on the
    // active schedule and the next tick reads the screen before delegating again (once
    // the press's settle window has passed).
    #expect(fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID] == seededScan)
    #expect(fixture.state.nextScheduleAfterTick(surfaceID: fixture.surfaceID, hasAgent: true) == .active)
    fixture.state.agentDetectionSchedules[fixture.surfaceID] = .active
    #expect(await detect(fixture))
    #expect(fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID]?.text == "")
    let settled = Date().addingTimeInterval(AgentDetectionSchedule.settleWindow + 1)
    #expect(
      fixture.state.nextScheduleAfterTick(surfaceID: fixture.surfaceID, hasAgent: true, now: settled) == .delegated)
  }

  @Test func probeMissLeavesDelegationForTheActiveCadence() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await delegate(fixture, probe: probe)

    probe.job = nil
    #expect(await detect(fixture))

    // Presence holds the agent and the authority, but the remaining misses must run
    // on the 300 ms cadence, not every 2 s.
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
    #expect(fixture.state.nextScheduleAfterTick(surfaceID: fixture.surfaceID, hasAgent: true) == .active)
  }

  @Test func engineChangeOnADelegatedTickRunsAFullAcquisition() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    // Spawned before the report so the root record postdates the engine's start.
    let engine = try spawnSleeper()
    defer { engine.terminate() }
    await delegate(fixture, probe: probe)

    // The identified process moved to another (real) pid: the bound generation is gone.
    probe.job = claudeJob(pid: engine.processIdentifier)
    #expect(await detect(fixture))

    // The screen was read (the memo holds the live frame) and the rebound coordinator
    // re-derived the evidence against the new generation.
    #expect(fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID]?.text == "")
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == .local(engine.processIdentifier))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.decision?.reason.identifier == "osc.working")
    #expect(
      fixture.state.agentDetectionCoordinators[fixture.surfaceID]?.boundProcess?.localGeneration?.pid
        == engine.processIdentifier)
  }

  @Test func nextScheduleFollowsDelegation() {
    let now = Date(timeIntervalSince1970: 100)
    let active = AgentDetectionSchedule.cold.warmed(now: now).observedAgent(now: now)
    #expect(WorktreeTerminalState.nextSchedule(active, hasAgent: true, delegated: true, now: now) == .delegated)
    #expect(WorktreeTerminalState.nextSchedule(.delegated, hasAgent: true, delegated: false, now: now) == .active)
    #expect(
      WorktreeTerminalState.nextSchedule(.delegated, hasAgent: false, delegated: false, now: now).nextInterval(now: now)
        == .seconds(2))
  }

  // MARK: Release on command finished

  @Test func commandFinishedReleasesOnASingleFreshMiss() async {
    let probe = Probe()
    let fixture = makeFixture(support: .unverified, probe: probe)
    var removed: [UUID] = []
    fixture.state.onAgentEntryRemoved = { removed.append($0) }
    await bind(fixture, probe: probe)
    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)
    fixture.state.handleProgramStatus(report(.done, id: "built"), surfaceID: fixture.surfaceID)
    probe.calls.removeAll()

    fixture.state.noteCommandFinishedForAgentDetection(surfaceID: fixture.surfaceID)
    #expect(fixture.state.agentDetectionWakeRequests.contains(fixture.surfaceID))
    probe.job = nil
    #expect(await detect(fixture) == false)

    // The wake's probe bypassed the cache and its miss released the entry at once.
    #expect(probe.calls == [true])
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)
    #expect(removed == [fixture.surfaceID])
    let store = fixture.state.programStatusStoresBySurface[fixture.surfaceID]
    #expect(store?.root == nil)
    #expect(store?.record(id: "built")?.state == .done)
  }

  @Test func secondCommandFinishedDuringTheFreshProbeKeepsItsOwnMark() async {
    let probe = Probe()
    let fixture = makeFixture(support: .unverified, probe: probe)
    await bind(fixture, probe: probe)
    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)
    fixture.state.noteCommandFinishedForAgentDetection(surfaceID: fixture.surfaceID)
    let firstMark = fixture.state.pendingCommandFinishedBySurface[fixture.surfaceID]

    let entered = AsyncStream<Void>.makeStream()
    probe.entered = entered.continuation
    let tick = Task { await self.detect(fixture) }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    // A successor reported and its shell prompt returned while the first fresh
    // sample was still in flight.
    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)
    fixture.state.noteCommandFinishedForAgentDetection(surfaceID: fixture.surfaceID)
    let secondMark = fixture.state.pendingCommandFinishedBySurface[fixture.surfaceID]
    #expect(secondMark != firstMark)
    probe.gate?.resume()
    #expect(await tick.value)

    // The first sample saw the agent (a nested shell's prompt): nothing was released,
    // and the second D still owns its mark and its fresh sample.
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
    #expect(fixture.state.pendingCommandFinishedBySurface[fixture.surfaceID] == secondMark)
    #expect(fixture.state.agentDetectionFreshProbeRequests.contains(fixture.surfaceID))
    #expect(fixture.state.programStatusStoresBySurface[fixture.surfaceID]?.root?.state == .working)
  }

  @Test func originChangeRetiresTheLaunchContextAndTheLocalBinding() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var emitted: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { emitted.append($0) }
    await bind(fixture, probe: probe)
    fixture.state.launchProfilesBySurface[fixture.surfaceID] = WorktreeTerminalState.SurfaceLaunchProfile(
      profileID: UUID(), name: "Claude · Bound", runtime: .claude, dedicatedHome: nil)
    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)

    // Inside the presence hold the same agent appears on a remote host with the same pid.
    let remote = ProcessRef.remote(
      RemoteProcessRef(
        connection: ConnectionKey(user: "onevcat", hostname: "mini.local"), bootID: "boot", pid: getpid(),
        startToken: "t1"))
    probe.job = ForegroundJob(
      processGroupID: getpid(),
      processes: [ForegroundProcess(ref: remote, parentPID: 1, name: "claude", argv0: "claude", cmdline: "claude")])
    emitted.removeAll()
    #expect(await detect(fixture))

    let pane = fixture.state.surfaceAgentStates[fixture.surfaceID]
    #expect(pane?.agentProcess == remote)
    #expect(pane?.launchProcess == remote)
    #expect(fixture.state.launchProfilesBySurface[fixture.surfaceID] == nil)
    #expect(emitted.last?.launchProfileName == nil)
    // The local root record does not count for the remote generation.
    #expect(
      fixture.state.agentDetectionCoordinators[fixture.surfaceID]?.boundProcess
        == .remote(
          RemoteProcessRef(
            connection: ConnectionKey(user: "onevcat", hostname: "mini.local"), bootID: "boot", pid: getpid(),
            startToken: "t1")))
    #expect(fixture.state.agentDetectionCoordinators[fixture.surfaceID]?.isDelegated == false)
    #expect(pane?.decision?.reason.identifier != "osc.working")
  }

  @Test func recordsFromADepartedOriginNeverDecideForTheReturningLocalAgent() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await bind(fixture, probe: probe)
    // The local agent is suspended; the same agent runs on a remote host and reports.
    let remote = ProcessRef.remote(
      RemoteProcessRef(
        connection: ConnectionKey(user: "onevcat", hostname: "mini.local"), bootID: "boot", pid: 7,
        startToken: "t1"))
    probe.job = ForegroundJob(
      processGroupID: 7,
      processes: [ForegroundProcess(ref: remote, parentPID: 1, name: "claude", argv0: "claude", cmdline: "claude")])
    #expect(await detect(fixture))
    fixture.state.handleProgramStatus(report(.done), surfaceID: fixture.surfaceID)
    fixture.state.handleProgramStatus(report(.blocked, id: "child"), surfaceID: fixture.surfaceID)

    // Back to the original local process, whose start predates the remote report.
    probe.job = claudeJob()
    fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID] = WorktreeTerminalState.AgentScreenScan(
      agent: .claude, text: "", detection: AgentScreenDetection(state: .working, reason: .legacyDetector))
    #expect(await detect(fixture))
    let coordinator = try #require(fixture.state.agentDetectionCoordinators[fixture.surfaceID])
    #expect(!coordinator.isDelegated)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.decision?.reason.identifier != "osc.done")
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .working)

    // A report from the local process after the return decides again; the remote
    // blocked child does not veto it.
    fixture.state.handleProgramStatus(report(.idle), surfaceID: fixture.surfaceID)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.decision?.reason.identifier == "osc.idle")
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .idle)
  }

  @Test func departedOriginReportsDuringTheReturningProbeNeverDecide() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await bind(fixture, probe: probe)
    let remote = ProcessRef.remote(
      RemoteProcessRef(
        connection: ConnectionKey(user: "onevcat", hostname: "mini.local"), bootID: "boot", pid: 7,
        startToken: "t1"))
    probe.job = ForegroundJob(
      processGroupID: 7,
      processes: [ForegroundProcess(ref: remote, parentPID: 1, name: "claude", argv0: "claude", cmdline: "claude")])
    #expect(await detect(fixture))

    // The poll that will see the local agent again starts; the remote reports are still
    // in flight and land while its probe runs.
    fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID] = WorktreeTerminalState.AgentScreenScan(
      agent: .claude, text: "", detection: AgentScreenDetection(state: .working, reason: .legacyDetector))
    let entered = AsyncStream<Void>.makeStream()
    probe.entered = entered.continuation
    let tick = Task { await self.detect(fixture) }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    fixture.state.handleProgramStatus(report(.done), surfaceID: fixture.surfaceID)
    fixture.state.handleProgramStatus(report(.blocked, id: "child"), surfaceID: fixture.surfaceID)
    probe.job = claudeJob()
    probe.gate?.resume()
    #expect(await tick.value)

    #expect(fixture.state.agentDetectionCoordinators[fixture.surfaceID]?.isDelegated == false)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .working)
    fixture.state.handleProgramStatus(report(.idle), surfaceID: fixture.surfaceID)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.decision?.reason.identifier == "osc.idle")
  }

  @Test func remoteLaunchNeverWearsALocalProfile() async throws {
    // The Profile's agent never appeared; the user ran `ssh host claude` in its pane.
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    fixture.state.launchProfilesBySurface[fixture.surfaceID] = WorktreeTerminalState.SurfaceLaunchProfile(
      profileID: UUID(), name: "Claude · Bound", runtime: .claude, dedicatedHome: nil)
    let remote = ProcessRef.remote(
      RemoteProcessRef(
        connection: ConnectionKey(user: "onevcat", hostname: "mini.local"), bootID: "boot", pid: 7,
        startToken: "t1"))
    probe.job = ForegroundJob(
      processGroupID: 7,
      processes: [ForegroundProcess(ref: remote, parentPID: 1, name: "claude", argv0: "claude", cmdline: "claude")])
    fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID] = WorktreeTerminalState.AgentScreenScan(
      agent: .claude, text: "", detection: AgentScreenDetection(state: .idle, reason: .legacyDetector))
    var emitted: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { emitted.append($0) }
    #expect(await detect(fixture))

    #expect(fixture.state.launchProfilesBySurface[fixture.surfaceID] == nil)
    #expect(emitted.last?.launchProfileName == nil)
  }

  @Test func successorAfterTheFinishedOwnerRetiresTheLaunchContextAndKeepsItsOwnRecords() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var removed: [UUID] = []
    var emitted: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryRemoved = { removed.append($0) }
    fixture.state.onAgentEntryChanged = { emitted.append($0) }
    let successor = try spawnDetachedSleeper()
    defer { kill(successor, SIGTERM) }
    await bind(fixture, probe: probe)
    fixture.state.launchProfilesBySurface[fixture.surfaceID] = WorktreeTerminalState.SurfaceLaunchProfile(
      profileID: UUID(), name: "Claude · Bound", runtime: .claude, dedicatedHome: nil)
    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)

    // The owner's shell prompt returned; a successor launched (another real pid) and
    // reported before the probe ran.
    fixture.state.noteCommandFinishedForAgentDetection(surfaceID: fixture.surfaceID)
    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)
    probe.job = claudeJob(pid: successor)
    emitted.removeAll()
    #expect(await detect(fixture))

    #expect(removed == [fixture.surfaceID])
    #expect(fixture.state.launchProfilesBySurface[fixture.surfaceID] == nil)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == .local(successor))
    #expect(emitted.last?.launchProfileName == nil)
    // The successor's root arrived after the D and survived the scoped cleanup, so it
    // drives the successor's decision without another report.
    #expect(fixture.state.programStatusStoresBySurface[fixture.surfaceID]?.root?.state == .working)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.decision?.reason.identifier == "osc.working")
  }

  @Test func agentWithoutReportsIsReleasedOnTheFreshMissToo() async {
    let probe = Probe()
    let fixture = makeFixture(support: .unverified, probe: probe)
    var removed: [UUID] = []
    fixture.state.onAgentEntryRemoved = { removed.append($0) }
    probe.job = ForegroundJob(
      processGroupID: getpid(),
      processes: [
        ForegroundProcess(pid: getpid(), parentProcessID: getppid(), name: "codex", argv0: "codex", cmdline: "codex")
      ])
    fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID] = WorktreeTerminalState.AgentScreenScan(
      agent: .codex, text: "", detection: AgentScreenDetection(state: .idle, reason: .legacyDetector))
    #expect(await detect(fixture))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .codex)

    fixture.state.noteCommandFinishedForAgentDetection(surfaceID: fixture.surfaceID)
    probe.job = nil
    #expect(await detect(fixture) == false)

    #expect(removed == [fixture.surfaceID])
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)
  }

  @Test func ordinaryMissStillNeedsSixSamples() async {
    let probe = Probe()
    let fixture = makeFixture(support: .unverified, probe: probe)
    await bind(fixture, probe: probe)
    probe.job = nil
    probe.calls.removeAll()

    #expect(await detect(fixture))

    #expect(probe.calls == [false])
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
  }

  @Test func nestedShellPromptDoesNotReleaseOrDropRecords() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await bind(fixture, probe: probe)
    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)

    fixture.state.noteCommandFinishedForAgentDetection(surfaceID: fixture.surfaceID)
    #expect(await detect(fixture))

    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
    #expect(fixture.state.programStatusStoresBySurface[fixture.surfaceID]?.root?.state == .working)
    #expect(fixture.state.agentDetectionCoordinators[fixture.surfaceID]?.isDelegated == true)
    #expect(fixture.state.pendingCommandFinishedBySurface[fixture.surfaceID] == nil)
  }

  @Test func commandFinishedOutcomeSeparatesOwnerFromEngine() {
    let launcher = IdentifiedAgentProcess(
      agent: .claude, name: "claude",
      process: ForegroundProcess(pid: 101, parentProcessID: 100, name: "claude", argv0: "claude", cmdline: nil),
      launchProcess: .local(100))
    let sameOwner = PaneAgentState(detectedAgent: .claude, agentProcess: .local(101), launchProcess: .local(100))
    #expect(
      WorktreeTerminalState.commandFinishedOutcome(
        identified: launcher, previous: sameOwner, isLiveAncestor: { _, _ in false })
        == .sameOwner)
    // The engine child was replaced while the launcher stayed a live ancestor.
    let replaced = IdentifiedAgentProcess(
      agent: .claude, name: "claude",
      process: ForegroundProcess(pid: 102, parentProcessID: 102, name: "claude", argv0: "claude", cmdline: nil),
      launchProcess: .local(102))
    #expect(
      WorktreeTerminalState.commandFinishedOutcome(
        identified: replaced, previous: sameOwner,
        isLiveAncestor: { ancestor, descendant in ancestor == .local(100) && descendant == .local(102) })
        == .sameOwner)
    // A successor launch: nothing links it to the finished owner.
    #expect(
      WorktreeTerminalState.commandFinishedOutcome(
        identified: replaced, previous: sameOwner, isLiveAncestor: { _, _ in false })
        == .successor)
    #expect(
      WorktreeTerminalState.commandFinishedOutcome(
        identified: nil, previous: sameOwner, isLiveAncestor: { _, _ in false })
        == .released)
    // A first agent appearing right after the prompt returned owns nothing yet.
    #expect(
      WorktreeTerminalState.commandFinishedOutcome(
        identified: replaced, previous: PaneAgentState(), isLiveAncestor: { _, _ in false })
        == .successor)
  }

  @Test func commandFinishedWithoutAnAgentDropsLiveRecordsDirectly() {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    fixture.state.handleProgramStatus(report(.working, app: "cargo"), surfaceID: fixture.surfaceID)
    fixture.state.handleProgramStatus(report(.done, id: "built", app: "cargo"), surfaceID: fixture.surfaceID)

    fixture.state.noteCommandFinishedForAgentDetection(surfaceID: fixture.surfaceID)

    let store = fixture.state.programStatusStoresBySurface[fixture.surfaceID]
    #expect(store?.root == nil)
    #expect(store?.record(id: "built")?.state == .done)
    #expect(fixture.state.pendingCommandFinishedBySurface[fixture.surfaceID] == nil)
  }

  // MARK: Wake

  @Test func wakeInterruptsASleepingLoop() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe, startsLoop: true)
    let calls = AsyncStream<Void>.makeStream()
    fixture.state.agentProcessProbeForTesting = { _, _, _ in
      calls.continuation.yield(())
      return nil
    }
    var iterator = calls.stream.makeAsyncIterator()
    fixture.state.wakeAgentDetection(for: fixture.surface, tabId: fixture.tabID)
    _ = await iterator.next()
    // The loop goes to sleep on the warm interval (2 s); a wake must end that sleep. The
    // check is on the sleeper, not on elapsed time: a loaded host can delay the loop.
    await waitUntil { fixture.state.agentDetectionSleepersBySurface[fixture.surfaceID] != nil }
    let sleeper = fixture.state.agentDetectionSleepersBySurface[fixture.surfaceID]?.task
    fixture.state.wakeAgentDetection(for: fixture.surface, tabId: fixture.tabID)
    #expect(sleeper?.isCancelled == true)
    _ = await iterator.next()
    fixture.state.cleanupAllAgentDetectionState()
  }

  @Test func aLateSleeperContinuationDoesNotUnregisterANewerLoopsSleeper() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    let id = fixture.surfaceID
    let old = Task { await fixture.state.sleepAgentDetection(forSurfaceID: id, token: 1, interval: .seconds(30)) }
    await waitUntil { fixture.state.agentDetectionSleepersBySurface[id] != nil }
    // The surface was closed and restored: a new loop owns the slot now.
    let newer = Task<Void, any Error> { try await Task.sleep(for: .seconds(30)) }
    fixture.state.agentDetectionSleepersBySurface[id] = WorktreeTerminalState.AgentDetectionSleeper(
      token: 2, task: newer)

    old.cancel()
    await old.value

    #expect(fixture.state.agentDetectionSleepersBySurface[id]?.token == 2)
    newer.cancel()
  }

  @Test func aStaleFreshProbeFromBeforeACloseCannotReleaseTheRestoredAgent() async {
    let probe = Probe()
    let fixture = makeFixture(support: .unverified, probe: probe)
    var removed: [UUID] = []
    fixture.state.onAgentEntryRemoved = { removed.append($0) }
    await bind(fixture, probe: probe)
    fixture.state.noteCommandFinishedForAgentDetection(surfaceID: fixture.surfaceID)
    // The old poll consumed the mark and is suspended in its fresh probe.
    let entered = AsyncStream<Void>.makeStream()
    probe.entered = entered.continuation
    let oldTick = Task { await self.detect(fixture) }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()

    // Close and undo: the same surface id comes back with fresh detection state, and
    // the restored pane binds its agent again.
    fixture.state.detachAndForgetSurface(fixture.surface)
    removed.removeAll()
    fixture.state.configureBridgeCallbacks(for: fixture.surface, tabId: fixture.tabID)
    fixture.state.surfaces[fixture.surfaceID] = fixture.surface
    fixture.state.agentDetectionTasks[fixture.surfaceID] = Task {}
    fixture.state.surfaceAgentStates[fixture.surfaceID] = PaneAgentState(lastChangedAt: epoch)
    fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID] = WorktreeTerminalState.AgentScreenScan(
      agent: .claude, text: "", detection: AgentScreenDetection(state: .idle, reason: .legacyDetector))
    #expect(await detect(fixture))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
    let restoredCoordinator = fixture.state.agentDetectionCoordinators[fixture.surfaceID]

    // The old probe lands with a miss from before the close.
    probe.job = nil
    probe.gate?.resume()
    #expect(await oldTick.value == false)

    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
    #expect(fixture.state.agentDetectionCoordinators[fixture.surfaceID] === restoredCoordinator)
    #expect(removed.isEmpty)
    #expect(fixture.state.agentDetectionPresenceBySurface[fixture.surfaceID]?.currentAgent == .claude)
  }

  // MARK: Undo-close

  @Test func retainedSurfaceKeepsFeedingTheStoreAndAppliesCommandFinishedDirectly() {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)

    fixture.state.detachAndForgetSurface(fixture.surface)

    #expect(fixture.state.programStatusStoresBySurface[fixture.surfaceID]?.root?.state == .working)
    fixture.surface.bridge.onProgramStatus?(report(.blocked, kind: .permission))
    #expect(fixture.state.programStatusStoresBySurface[fixture.surfaceID]?.root?.state == .blocked)
    #expect(fixture.state.agentDetectionTasks[fixture.surfaceID] == nil)

    fixture.surface.bridge.onCommandFinished?(0, 0)
    #expect(fixture.state.programStatusStoresBySurface[fixture.surfaceID]?.root == nil)
  }

  @Test func freeingASurfaceDropsItsStore() {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)
    fixture.state.detachAndForgetSurface(fixture.surface)
    #expect(fixture.state.programStatusStoresBySurface[fixture.surfaceID] != nil)

    fixture.state.dropProgramStatusStores(forSurfaceIDs: [fixture.surfaceID])
    #expect(fixture.state.programStatusStoresBySurface[fixture.surfaceID] == nil)
  }

  @Test func plainCloseDropsTheStore() {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)

    fixture.state.forgetSurface(fixture.surfaceID)

    #expect(fixture.state.programStatusStoresBySurface[fixture.surfaceID] == nil)
  }

  @Test func unmappedAppIsLoggedOncePerSurface() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var lines: [String] = []
    fixture.state.programStatusLogForTesting = { lines.append($0) }
    await bind(fixture, probe: probe)

    fixture.state.handleProgramStatus(report(.working, app: "cargo"), surfaceID: fixture.surfaceID)
    #expect(await detect(fixture))
    fixture.state.handleProgramStatus(report(.done, app: "cargo"), surfaceID: fixture.surfaceID)
    #expect(await detect(fixture))

    #expect(lines.filter { $0.contains("app=cargo unmapped") }.count == 1)
  }

  @Test func knownProducerRecordOnAPaneWithoutAnAgentIsNotUnmapped() async {
    // Pi's `done` survives the command-finished cleanup; after the release the pane has
    // no agent, and that leftover is not a new producer.
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var lines: [String] = []
    fixture.state.programStatusLogForTesting = { lines.append($0) }
    fixture.state.handleProgramStatus(report(.done, app: "pi"), surfaceID: fixture.surfaceID)
    #expect(await detect(fixture) == false)
    #expect(lines.isEmpty)
    fixture.state.handleProgramStatus(report(.done, app: "cargo"), surfaceID: fixture.surfaceID)
    #expect(await detect(fixture) == false)
    #expect(lines.filter { $0.contains("app=cargo unmapped") }.count == 1)
  }
}
