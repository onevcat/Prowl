import Foundation
import GhosttyKit
import Testing

@testable import Prowl

/// SSH-transparent detection in the terminal owner (docs-ai 082, S3a): a pane whose
/// foreground is a local `ssh` reports the remote agent the host's snapshots show. The local
/// probe and the snapshot source are fakes; the `ssh` member is this test process, so its
/// generation has a real start time.
@MainActor
@Suite(.serialized)
struct RemoteAgentDetectionTests {
  private struct Fixture {
    let state: WorktreeTerminalState
    let tabID: TerminalTabID
    let surface: GhosttySurfaceView
    let source: FakeRemoteSource
    var surfaceID: UUID { surface.id }
  }

  private final class Probe {
    var job: ForegroundJob?
    /// When set, the next probe call suspends here until resumed.
    var gate: CheckedContinuation<Void, Never>?
    var entered: AsyncStream<Void>.Continuation?
  }

  nonisolated final class FakeRemoteSource: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<RemoteProbeSnapshot>.Continuation?
    private var storedRecipes: [SSHConnectionRecipe] = []
    private var storedRefreshes = 0
    private var storedCloses = 0
    let connection = ConnectionKey(user: "onevcat", hostname: "mini.local")

    var recipes: [SSHConnectionRecipe] { lock.withLock { storedRecipes } }
    var refreshes: Int { lock.withLock { storedRefreshes } }
    var closes: Int { lock.withLock { storedCloses } }

    var source: RemoteSnapshotSource {
      RemoteSnapshotSource { [self] recipe in connect(recipe) }
    }

    private func connect(_ recipe: SSHConnectionRecipe) -> RemoteConnectionLease {
      let (stream, continuation) = AsyncStream<RemoteProbeSnapshot>.makeStream()
      lock.withLock {
        self.continuation = continuation
        storedRecipes.append(recipe)
      }
      return RemoteConnectionLease(
        connection: connection, snapshots: stream,
        refresh: { [self] in lock.withLock { storedRefreshes += 1 } },
        close: { [self] in lock.withLock { storedCloses += 1 } })
    }

    func push(_ snapshot: RemoteProbeSnapshot) {
      _ = lock.withLock { continuation }?.yield(snapshot)
    }
  }

  private func makeFixture(probe: Probe, enabled: Bool = true) -> Fixture {
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: Worktree(
        id: "/tmp/repo/worktree", name: "worktree", detail: "",
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/worktree"),
        repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")),
      skipsSurfaceCreationForTesting: true)
    let source = FakeRemoteSource()
    state.remoteAgentDetectionEnabledForTesting = enabled
    state.remoteSnapshotSourceForTesting = source.source
    state.programStatusSupportForTesting = { _ in .verified }
    state.agentProcessProbeForTesting = { _, _, _ in
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
      runtime: state.runtime, workingDirectory: URL(fileURLWithPath: "/tmp/repo/worktree", isDirectory: true),
      fontSize: nil, context: GHOSTTY_SURFACE_CONTEXT_TAB, skipsSurfaceCreationForTesting: true)
    state.configureBridgeCallbacks(for: surface, tabId: tabID)
    state.configureSurfaceCallbacks(for: surface, tabId: tabID)
    state.surfaces[surface.id] = surface
    state.trees[tabID] = SplitTree<GhosttySurfaceView>(view: surface)
    state.focusedSurfaceIdByTab[tabID] = surface.id
    state.surfaceAgentStates[surface.id] = PaneAgentState(lastChangedAt: Date(timeIntervalSince1970: 1_000))
    state.agentDetectionTasks[surface.id] = Task {}
    return Fixture(state: state, tabID: tabID, surface: surface, source: source)
  }

  private var sshJob: ForegroundJob {
    ForegroundJob(
      processGroupID: getpid(),
      processes: [
        ForegroundProcess(
          pid: getpid(), parentProcessID: 1, name: "ssh", argv0: "ssh", cmdline: "ssh -p 2222 mini",
          arguments: ["ssh", "-p", "2222", "mini"])
      ])
  }

  private func remoteProcess(_ pid: Int32, name: String, start: String = "t1") -> RemoteProbeProcess {
    RemoteProbeProcess(
      pid: pid, parentPID: 100, processGroupID: pid, startToken: start, elapsedSeconds: 1, name: name,
      arguments: [name], commandLine: name, workingDirectory: "/home/dev")
  }

  private func snapshot(
    _ sequence: UInt64, pane: UUID?, foreground: RemoteProbeProcess?, extraPane: UUID? = nil,
    outcome: RemoteProbeSnapshot.Outcome = .complete, anchor: Int32 = 100, epoch: UInt64 = 0,
    bootID: String = "boot"
  ) -> RemoteProbeSnapshot {
    func session(_ id: UUID?) -> RemoteProbeSession {
      let process = foreground ?? remoteProcess(101, name: "zsh")
      return RemoteProbeSession(
        paneID: id, anchorPID: anchor, tty: "/dev/pts/0", foregroundProcessGroupID: process.processGroupID,
        processes: [process])
    }
    var sessions = [session(pane)]
    if let extraPane { sessions.append(session(extraPane)) }
    let now = ProcessInfo.processInfo.systemUptime
    return RemoteProbeSnapshot(
      connection: ConnectionKey(user: "onevcat", hostname: "mini.local"), connectionEpoch: epoch, sequence: sequence,
      startedAt: now, finishedAt: now, outcome: outcome,
      report: RemoteProbeReport(operatingSystem: .linux, bootID: bootID, sessions: sessions))
  }

  private func remoteRef(_ pid: Int32, start: String = "t1") -> ProcessRef {
    .remote(
      RemoteProcessRef(
        connection: ConnectionKey(user: "onevcat", hostname: "mini.local"), bootID: "boot", pid: pid,
        startToken: start))
  }

  private func noSession(
    _: IdentifiedAgentProcess?, _: PaneAgentState, _: URL?, _: String, _: (surfaceID: UUID, configRoot: URL?)
  ) -> (session: AgentSession?, missStreak: Int) {
    (nil, 0)
  }

  @discardableResult
  private func detect(_ fixture: Fixture, screen: AgentRawState = .idle) async -> Bool {
    fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID] = WorktreeTerminalState.AgentScreenScan(
      agent: .claude, text: "", detection: AgentScreenDetection(state: screen, reason: .legacyDetector))
    return await fixture.state.detectAgentState(
      for: fixture.surface, tabId: fixture.tabID, resolveSession: noSession, now: Date())
  }

  /// Waits for the tracker's consumer task, which runs on the main actor between test steps.
  private func settle(_ condition: () -> Bool) async {
    for _ in 0..<1_000 where !condition() {
      await Task.yield()
    }
    #expect(condition())
  }

  private func deliver(_ fixture: Fixture, _ snapshot: RemoteProbeSnapshot) async {
    fixture.source.push(snapshot)
    await settle { fixture.state.remotePaneTrackers[fixture.surfaceID]?.latest?.sequence == snapshot.sequence }
  }

  /// Binds Claude through a first snapshot; returns after the entry is published.
  private func bindClaude(_ fixture: Fixture, probe: Probe) async {
    probe.job = sshJob
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    await deliver(fixture, snapshot(1, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude")))
    await detect(fixture)
  }

  @Test func aCorrelatedRemoteAgentAppearsWithItsRemoteReference() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var emitted: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { emitted.append($0) }
    await bindClaude(fixture, probe: probe)

    #expect(fixture.source.recipes.map(\.destination) == ["mini"])
    #expect(fixture.source.recipes.first?.options == ["-p", "2222"])
    // Relative operands resolve where the user's `ssh` runs.
    #expect(fixture.source.recipes.first?.workingDirectory == ProcessDetection.currentDirectory(pid: getpid()))
    let pane = fixture.state.surfaceAgentStates[fixture.surfaceID]
    #expect(pane?.detectedAgent == .claude)
    #expect(pane?.agentProcess == remoteRef(200))
    #expect(emitted.last?.agent == .claude)
    // No local file evidence for a remote process.
    #expect(pane?.session == nil)
    #expect(fixture.state.agentDetectionCoordinators[fixture.surfaceID]?.boundProcess?.localGeneration == nil)
  }

  @Test func twoCompleteSnapshotsWithoutTheAgentReleaseIt() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var removed: [UUID] = []
    fixture.state.onAgentEntryRemoved = { removed.append($0) }
    await bindClaude(fixture, probe: probe)

    // A tick with no new snapshot changes nothing.
    await detect(fixture)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
    // An inconclusive run neither proves absence nor resets the count.
    await deliver(fixture, snapshot(2, pane: fixture.surfaceID, foreground: nil, outcome: .partial))
    await detect(fixture)
    // Back at a system shell, macOS hides the pane id; the session is known by its anchor.
    await deliver(fixture, snapshot(3, pane: nil, foreground: nil))
    await detect(fixture)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
    #expect(removed.isEmpty)
    await deliver(fixture, snapshot(4, pane: nil, foreground: nil))
    await detect(fixture)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)
    #expect(removed == [fixture.surfaceID])
  }

  @Test func unmappedOrAmbiguousScansNeverReleaseABoundAgent() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await bindClaude(fixture, probe: probe)
    let claude = remoteProcess(200, name: "claude")
    // Another anchor without a pane id, then this pane's id twice: neither is evidence.
    for sequence in UInt64(2)...4 {
      await deliver(fixture, snapshot(sequence, pane: nil, foreground: nil, anchor: 900))
      await detect(fixture)
    }
    await deliver(fixture, snapshot(5, pane: fixture.surfaceID, foreground: nil, extraPane: fixture.surfaceID))
    await detect(fixture)
    await deliver(fixture, snapshot(6, pane: fixture.surfaceID, foreground: nil, extraPane: fixture.surfaceID))
    await detect(fixture)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == remoteRef(200))
    // Mapped evidence counts again as soon as it returns.
    await deliver(fixture, snapshot(7, pane: fixture.surfaceID, foreground: claude))
    await detect(fixture)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
  }

  @Test func anAnchorFromAnotherEpochOrBootIdentifiesNothing() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await bindClaude(fixture, probe: probe)
    // The host rebooted while the connection was down: a pane-less session reuses the
    // anchor pid and runs another agent. Neither releases nor replaces the binding.
    await deliver(
      fixture,
      snapshot(2, pane: nil, foreground: remoteProcess(999, name: "claude"), epoch: 1, bootID: "boot-2"))
    await detect(fixture)
    await deliver(fixture, snapshot(3, pane: nil, foreground: nil, epoch: 1, bootID: "boot-2"))
    await detect(fixture)
    await deliver(fixture, snapshot(4, pane: nil, foreground: nil, epoch: 1, bootID: "boot-2"))
    await detect(fixture)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == remoteRef(200))
    // A new epoch on the same boot is a new scope too.
    await deliver(fixture, snapshot(5, pane: nil, foreground: remoteProcess(998, name: "claude"), epoch: 2))
    await detect(fixture)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == remoteRef(200))
  }

  @Test func aRecreatedTrackerKeepsTheSuccessorFenceOfItsSSH() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await bindClaude(fixture, probe: probe)
    await deliver(fixture, snapshot(2, pane: fixture.surfaceID, foreground: remoteProcess(300, name: "claude")))
    await detect(fixture)
    let fence = try #require(fixture.state.agentDetectionCoordinators[fixture.surfaceID]?.remoteProgramStatusFence)
    let sshStart = try #require(ProcessDetection.processStartDate(pid: getpid()))
    #expect(fence > sshStart)

    // A close retained for undo retires the tracker and keeps the record store; the
    // restored pane gets a new tracker for the same `ssh`.
    fixture.state.retireRemotePaneTracker(surfaceID: fixture.surfaceID)
    await detect(fixture)
    await settle { fixture.source.recipes.count == 2 }
    await deliver(fixture, snapshot(1, pane: fixture.surfaceID, foreground: remoteProcess(300, name: "claude")))
    await detect(fixture)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == remoteRef(300))
    #expect(fixture.state.agentDetectionCoordinators[fixture.surfaceID]?.remoteProgramStatusFence == fence)
    // Dropping the store for good drops the fence with it.
    fixture.state.dropProgramStatusStores(forSurfaceIDs: [fixture.surfaceID])
    #expect(fixture.state.remoteFenceHistoryBySurface[fixture.surfaceID] == nil)
  }

  @Test func aLocalAgentBetweenSuspendAndResumeNeverDecidesForTheReturningRemoteAgent() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await bindClaude(fixture, probe: probe)
    // Ctrl-Z on the `ssh`, a local Claude runs in the pane and ends with a `done` root.
    probe.job = ForegroundJob(
      processGroupID: getpid(),
      processes: [
        ForegroundProcess(pid: getpid(), parentProcessID: 1, name: "claude", argv0: "claude", cmdline: "claude")
      ])
    await detect(fixture)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == .local(getpid()))
    fixture.state.handleProgramStatus(
      GhosttyProgramStatusReport(state: .done, kind: nil, id: "", app: "claude-code"), surfaceID: fixture.surfaceID)
    // `fg`: the same remote Claude is still at its permission prompt and sends nothing.
    probe.job = sshJob
    await detect(fixture, screen: .blocked)
    await settle { fixture.source.recipes.count == 2 }
    await deliver(fixture, snapshot(1, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude")))
    await detect(fixture, screen: .blocked)
    let pane = fixture.state.surfaceAgentStates[fixture.surfaceID]
    #expect(pane?.agentProcess == remoteRef(200))
    #expect(pane?.decision?.reason.identifier != "osc.done")
    #expect(pane?.state == .blocked)
  }

  @Test func sshPanesKeepTickingOnTheRemoteCadence() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    #expect(fixture.state.remoteAdjustedInterval(surfaceID: fixture.surfaceID, nil) == nil)
    #expect(fixture.state.remoteAdjustedInterval(surfaceID: fixture.surfaceID, .seconds(2)) == .seconds(2))
    probe.job = sshJob
    await detect(fixture)
    // No agent: never cold, at most every three seconds.
    #expect(fixture.state.remoteAdjustedInterval(surfaceID: fixture.surfaceID, nil) == .seconds(3))
    #expect(
      fixture.state.remoteAdjustedInterval(surfaceID: fixture.surfaceID, .milliseconds(300)) == .milliseconds(300))
    await settle { fixture.source.recipes.count == 1 }
    await deliver(fixture, snapshot(1, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude")))
    await detect(fixture)
    // A bound agent (even a delegated one on the two-second schedule) ticks every second.
    #expect(fixture.state.remoteAdjustedInterval(surfaceID: fixture.surfaceID, .seconds(2)) == .seconds(1))
  }

  @Test func predecessorReportsDuringTheConfirmingProbeNeverDecideForTheSuccessor() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await bindClaude(fixture, probe: probe)
    fixture.state.handleProgramStatus(
      GhosttyProgramStatusReport(state: .working, kind: nil, id: "", app: "claude-code"), surfaceID: fixture.surfaceID)
    // The tick that will see the successor starts; while its local probe runs, the
    // successor's snapshot arrives and the predecessor's last reports land.
    let entered = AsyncStream<Void>.makeStream()
    probe.entered = entered.continuation
    let tick = Task { await self.detect(fixture) }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    await deliver(fixture, snapshot(2, pane: fixture.surfaceID, foreground: remoteProcess(300, name: "claude")))
    fixture.state.handleProgramStatus(
      GhosttyProgramStatusReport(state: .done, kind: nil, id: "", app: "claude-code"), surfaceID: fixture.surfaceID)
    fixture.state.handleProgramStatus(
      GhosttyProgramStatusReport(state: .blocked, kind: nil, id: "child", app: "claude-code"),
      surfaceID: fixture.surfaceID)
    probe.gate?.resume()
    _ = await tick.value
    let pane = fixture.state.surfaceAgentStates[fixture.surfaceID]
    #expect(pane?.agentProcess == remoteRef(300))
    #expect(pane?.decision?.reason.identifier != "osc.done")
    #expect(pane?.state != .blocked)
  }

  @Test func theLocalSSHExitingReleasesAtOnceAndClosesTheLease() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var removed: [UUID] = []
    fixture.state.onAgentEntryRemoved = { removed.append($0) }
    await bindClaude(fixture, probe: probe)

    probe.job = ForegroundJob(
      processGroupID: getpid(),
      processes: [ForegroundProcess(pid: getpid(), parentProcessID: 1, name: "zsh", argv0: "zsh", cmdline: "zsh")])
    await detect(fixture)
    #expect(removed == [fixture.surfaceID])
    #expect(fixture.state.remotePaneTrackers[fixture.surfaceID] == nil)
    await settle { fixture.source.closes == 1 }
  }

  @Test func aLateSnapshotAfterTheSSHExitedResurrectsNothing() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await bindClaude(fixture, probe: probe)
    probe.job = nil
    await detect(fixture)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)
    fixture.source.push(snapshot(9, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude")))
    for _ in 0..<100 { await Task.yield() }
    await detect(fixture)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)
  }

  @Test func otherPanesAndAmbiguousSessionsNeverBind() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    probe.job = sshJob
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    let claude = remoteProcess(200, name: "claude")

    await deliver(fixture, snapshot(1, pane: UUID(), foreground: claude))
    await detect(fixture)
    let tracker = try #require(fixture.state.remotePaneTrackers[fixture.surfaceID])
    #expect(tracker.correlation == .unmapped)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)

    await deliver(fixture, snapshot(2, pane: fixture.surfaceID, foreground: claude, extraPane: fixture.surfaceID))
    await detect(fixture)
    #expect(tracker.correlation == .ambiguous)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)
  }

  @Test func aProxyJumpHelperNeverStandsInForTheTerminalsSSH() async throws {
    // `ssh -J jump target` runs `ssh -W … jump` as its child in the same job; the helper is
    // listed first. Its own process is real so its generation is readable.
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    helper.arguments = ["30"]
    try helper.run()
    defer { helper.terminate() }
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    probe.job = ForegroundJob(
      processGroupID: getpid(),
      processes: [
        ForegroundProcess(
          pid: helper.processIdentifier, parentProcessID: getpid(), name: "ssh", argv0: "ssh",
          cmdline: "ssh -W [127.0.0.1]:22 jump", arguments: ["/usr/bin/ssh", "-W", "[127.0.0.1]:22", "jump"]),
        ForegroundProcess(
          pid: getpid(), parentProcessID: 1, name: "ssh", argv0: "ssh", cmdline: "ssh -J jump dev@target",
          arguments: ["ssh", "-J", "jump", "dev@target"]),
      ])
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    #expect(fixture.source.recipes.first?.destination == "dev@target")
    #expect(fixture.source.recipes.first?.options == ["-J", "jump"])
  }

  @Test func unsupportedArgvNeverConnects() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    probe.job = ForegroundJob(
      processGroupID: getpid(),
      processes: [
        ForegroundProcess(
          pid: getpid(), parentProcessID: 1, name: "ssh", argv0: "ssh", cmdline: "ssh -N -L 1:a:1 box",
          arguments: ["ssh", "-N", "-L", "1:a:1", "box"])
      ])
    await detect(fixture)
    for _ in 0..<50 { await Task.yield() }
    let tracker = try #require(fixture.state.remotePaneTrackers[fixture.surfaceID])
    guard case .unsupported = tracker.correlation else {
      Issue.record("expected unsupported, got \(tracker.correlation)")
      return
    }
    #expect(fixture.source.recipes.isEmpty)
  }

  @Test func remoteReportsCountFromTheSSHStartAndASuccessorStartsANewFence() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    probe.job = sshJob
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    // Claude reported before the first snapshot confirmed it; the report is after the
    // `ssh` started, so it counts once the agent binds.
    fixture.state.handleProgramStatus(
      GhosttyProgramStatusReport(state: .working, kind: nil, id: "", app: "claude-code"), surfaceID: fixture.surfaceID)
    await deliver(fixture, snapshot(1, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude")))
    await detect(fixture)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.decision?.reason.identifier == "osc.working")
    let sshStart = try #require(ProcessDetection.processStartDate(pid: getpid()))
    #expect(fixture.state.agentDetectionCoordinators[fixture.surfaceID]?.remoteProgramStatusFence == sshStart)
    // Ticks without a new snapshot still see the bound generation, so the verified
    // producer's root delegates the screen read.
    await detect(fixture)
    #expect(fixture.state.agentDetectionCoordinators[fixture.surfaceID]?.isDelegated == true)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == remoteRef(200))

    // A successor replaced Claude between snapshots: the predecessor's report no longer
    // counts; the screen decides until the successor reports.
    await deliver(fixture, snapshot(2, pane: fixture.surfaceID, foreground: remoteProcess(300, name: "claude")))
    await detect(fixture)
    let pane = fixture.state.surfaceAgentStates[fixture.surfaceID]
    #expect(pane?.agentProcess == remoteRef(300))
    #expect(pane?.decision?.reason.identifier != "osc.working")
    fixture.state.handleProgramStatus(
      GhosttyProgramStatusReport(state: .idle, kind: nil, id: "", app: "claude-code"), surfaceID: fixture.surfaceID)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.decision?.reason.identifier == "osc.idle")
  }

  @Test func theFlagOffNeverStartsATracker() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe, enabled: false)
    probe.job = sshJob
    await detect(fixture)
    #expect(fixture.state.remotePaneTrackers.isEmpty)
    #expect(fixture.source.recipes.isEmpty)
  }

  @Test func ticksRequestSnapshotsOnTheirCadenceAndWakesAtOnce() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    probe.job = sshJob
    await detect(fixture)
    await settle { fixture.source.refreshes == 1 }
    // Ticks inside the cadence do not ask again.
    await detect(fixture)
    await detect(fixture)
    for _ in 0..<50 { await Task.yield() }
    #expect(fixture.source.refreshes == 1)
    // A wake asks on the next tick.
    let tracker = try #require(fixture.state.remotePaneTrackers[fixture.surfaceID])
    tracker.requestSoon()
    await detect(fixture)
    await settle { fixture.source.refreshes == 2 }
  }

  @Test func paneShellsExportThePaneIdUnderAnSSHForwardedName() {
    let surface = GhosttySurfaceView(
      runtime: GhosttyRuntime(), workingDirectory: nil, fontSize: nil, context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true)
    #expect(surface.launchEnvironment["LC_PROWL_PANE"] == surface.id.uuidString)
    #expect(surface.launchEnvironment["PROWL_PANE_ID"] == surface.id.uuidString)
  }
}
