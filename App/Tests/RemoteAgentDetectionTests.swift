import Foundation
import GhosttyKit
import ProwlCLIShared
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
    private var storedFailures = 0
    private var storedAttempts = 0
    let connection = ConnectionKey(user: "onevcat", hostname: "mini.local")

    var attempts: Int { lock.withLock { storedAttempts } }
    /// The next `count` connects fail as an unresolvable recipe would.
    func failNext(_ count: Int) { lock.withLock { storedFailures = count } }

    var recipes: [SSHConnectionRecipe] { lock.withLock { storedRecipes } }
    var refreshes: Int { lock.withLock { storedRefreshes } }
    var closes: Int { lock.withLock { storedCloses } }

    var source: RemoteSnapshotSource {
      RemoteSnapshotSource { [self] recipe in
        let fails = lock.withLock {
          storedAttempts += 1
          guard storedFailures > 0 else { return false }
          storedFailures -= 1
          return true
        }
        return fails ? nil : connect(recipe)
      }
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

  /// The pane's shell in front again: what the probe reads once the `ssh` exited.
  private var shellJob: ForegroundJob {
    ForegroundJob(
      processGroupID: getpid(),
      processes: [ForegroundProcess(pid: getpid(), parentProcessID: 1, name: "zsh", argv0: "zsh", cmdline: "zsh")])
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
  private func detect(_ fixture: Fixture, screen: AgentRawState = .idle, now: Date = Date()) async -> Bool {
    fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID] = WorktreeTerminalState.AgentScreenScan(
      agent: .claude, text: "", detection: AgentScreenDetection(state: screen, reason: .legacyDetector))
    return await fixture.state.detectAgentState(
      for: fixture.surface, tabId: fixture.tabID, resolveSession: noSession, now: now)
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

  @Test func aRemotePaneShowsItsHostOnThePaneAndItsTab() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await bindClaude(fixture, probe: probe)
    #expect(fixture.surface.bridge.state.remoteIndicator?.connectedHost == "onevcat@mini.local")
    #expect(fixture.state.tabManager.tabs.first?.remoteHosts == ["onevcat@mini.local"])
    // A suspended `ssh` (still running) only drops the label.
    probe.job = shellJob
    await detect(fixture)
    #expect(fixture.surface.bridge.state.remoteIndicator == nil)
    #expect(fixture.state.tabManager.tabs.first?.remoteHosts == [])
  }

  /// A spawned process that stands in for a local `ssh` client, so it has its own generation.
  private func spawnSSH(_ arguments: [String] = ["ssh", "-p", "2222", "mini"]) throws -> (Process, ForegroundJob) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    let pid = process.processIdentifier
    let job = ForegroundJob(
      processGroupID: pid,
      processes: [
        ForegroundProcess(
          pid: pid, parentProcessID: 1, name: "ssh", argv0: "ssh", cmdline: arguments.joined(separator: " "),
          arguments: arguments)
      ])
    return (process, job)
  }

  private func connect(_ fixture: Fixture, probe: Probe, job: ForegroundJob) async {
    probe.job = job
    await detect(fixture)
    await settle { fixture.state.remotePaneTrackers[fixture.surfaceID] != nil }
    await settle { !fixture.source.recipes.isEmpty }
    await deliver(
      fixture,
      snapshot(
        (fixture.state.remotePaneTrackers[fixture.surfaceID]?.latest?.sequence ?? 0) + 1, pane: fixture.surfaceID,
        foreground: remoteProcess(200, name: "zsh")))
    await detect(fixture)
  }

  @Test func anExitedSSHLeavesAnEndedMarkerForItsDuration() async throws {
    let (ssh, job) = try spawnSSH()
    defer { if ssh.isRunning { ssh.terminate() } }
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await connect(fixture, probe: probe, job: job)
    #expect(fixture.surface.bridge.state.remoteIndicator?.connectedHost == "onevcat@mini.local")
    ssh.terminate()
    ssh.waitUntilExit()
    probe.job = shellJob
    let exitedAt = Date()
    await detect(fixture, now: exitedAt)
    // Detection stamps the sample no earlier than the wall clock.
    guard case .ended(let host, let endedAt) = fixture.surface.bridge.state.remoteIndicator else {
      Issue.record("no ended marker")
      return
    }
    #expect(host == "onevcat@mini.local")
    #expect(endedAt >= exitedAt)
    #expect(fixture.state.tabManager.tabs.first?.remoteHosts == [])
    // After its duration the marker is gone from the state, not only from one view.
    await detect(fixture, now: endedAt.addingTimeInterval(RemotePaneIndicator.endedMarkerDuration + 1))
    #expect(fixture.surface.bridge.state.remoteIndicator == nil)
  }

  @Test func theEndedMarkerDescribesOneExit() {
    let endedAt = Date(timeIntervalSince1970: 1_000)
    let ended = RemotePaneIndicator.ended(host: "h", endedAt: endedAt)
    #expect(ended.showsEndedMarker(now: endedAt.addingTimeInterval(4)))
    // A view mounted later (a tab switch, a new split) does not show it again.
    #expect(!ended.showsEndedMarker(now: endedAt.addingTimeInterval(5)))
    #expect(!RemotePaneIndicator.connected(host: "h", ssh: sshGeneration).showsEndedMarker(now: endedAt))
  }

  @Test func aRestoredPaneWhoseSSHExitedDropsTheConnectedLabel() async throws {
    let (ssh, job) = try spawnSSH()
    defer { if ssh.isRunning { ssh.terminate() } }
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await connect(fixture, probe: probe, job: job)
    // Close (the tracker retires, the surface is retained), the `ssh` exits, then Undo.
    fixture.state.retireRemotePaneTracker(surfaceID: fixture.surfaceID)
    ssh.terminate()
    ssh.waitUntilExit()
    probe.job = shellJob
    await detect(fixture)
    #expect(fixture.surface.bridge.state.remoteIndicator?.connectedHost == nil)
    #expect(fixture.state.tabManager.tabs.first?.remoteHosts == [])
  }

  @Test func aReplacementSSHNeverInheritsThePreviousHost() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await bindClaude(fixture, probe: probe)
    #expect(fixture.surface.bridge.state.remoteIndicator?.connectedHost == "onevcat@mini.local")
    // The next sampled job is another `ssh` that cannot be resolved (`-N` is unsupported).
    let (other, job) = try spawnSSH(["ssh", "-N", "-L", "8080:localhost:80", "hostB"])
    defer { other.terminate() }
    probe.job = job
    await detect(fixture)
    // It is labelled as itself: an `ssh` Prowl cannot read, never as A.
    guard case .connected(let host, let ssh, let issue) = fixture.surface.bridge.state.remoteIndicator else {
      Issue.record("no label for the replacement ssh")
      return
    }
    #expect(host == "Remote host")
    #expect(ssh.pid == other.processIdentifier)
    if case .unsupported = issue {
    } else {
      Issue.record("expected an unsupported issue, got \(String(describing: issue))")
    }
    #expect(fixture.state.tabManager.tabs.first?.remoteHosts == ["Remote host"])
  }

  @Test func aPaneWithoutAnAgentStillReportsWhyItIsNotRead() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    probe.job = sshJob
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    // The host answers, but no session carries this pane's id, and no producer reports.
    await deliver(fixture, snapshot(1, pane: nil, foreground: nil))
    await detect(fixture)
    #expect(
      fixture.surface.bridge.state.remoteIndicator
        == .connected(
          host: "onevcat@mini.local", ssh: sshGeneration, issue: .unmapped))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)
    // Once the pane maps, the issue goes.
    await deliver(fixture, snapshot(2, pane: fixture.surfaceID, foreground: remoteProcess(101, name: "zsh")))
    await detect(fixture)
    #expect(
      fixture.surface.bridge.state.remoteIndicator
        == .connected(
          host: "onevcat@mini.local", ssh: sshGeneration, issue: nil))
  }

  @Test func thePaneAccessibilityElementCarriesTheRemoteState() {
    let surface = GhosttySurfaceView(
      runtime: GhosttyRuntime(), workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true), fontSize: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB, skipsSurfaceCreationForTesting: true)
    surface.bridge.state.title = "Claude Code"
    surface.setAccessibilityPaneIndex(index: 1, total: 2)
    #expect(surface.accessibilityLabel() == "Claude Code")
    #expect(surface.accessibilityHelp() == "Pane 1 of 2")
    surface.bridge.state.remoteIndicator = .connected(host: "dev@box", ssh: sshGeneration, issue: .unmapped)
    #expect(surface.accessibilityLabel() == "Claude Code, connected to dev@box")
    #expect(surface.accessibilityHelp()?.hasPrefix("Pane 1 of 2 dev@box has no session for this pane.") == true)
    surface.bridge.state.remoteIndicator = .ended(host: "dev@box", endedAt: Date())
    #expect(surface.accessibilityLabel() == "Claude Code, disconnected from dev@box")
    // An old exit is not announced.
    surface.bridge.state.remoteIndicator = .ended(host: "dev@box", endedAt: Date().addingTimeInterval(-10))
    #expect(surface.accessibilityLabel() == "Claude Code")
    surface.bridge.state.remoteIndicator = nil
    #expect(surface.accessibilityHelp() == "Pane 1 of 2")
  }

  @Test func anUnreachableHostIsReportedWithoutAnAgent() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    fixture.source.failNext(100)
    probe.job = sshJob
    await detect(fixture)
    let tracker = try #require(fixture.state.remotePaneTrackers[fixture.surfaceID])
    await settle { tracker.correlation == .probeUnavailable(nil) }
    await detect(fixture)
    guard case .connected(_, _, .probeUnavailable?) = fixture.surface.bridge.state.remoteIndicator else {
      Issue.record("expected a probe-unavailable issue")
      return
    }
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)
    #expect(
      RemoteAgentPresentation.paneIssueExplanation(.probeUnavailable(.authentication), host: "h")
        == "Prowl cannot read h: the key was refused or needs a prompt. "
        + "Agents in this pane are detected only when they report their status themselves (OSC 7501).")
  }

  @Test func turningDetectionOffClearsTheRemoteLabel() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await bindClaude(fixture, probe: probe)
    fixture.state.remoteAgentDetectionEnabledForTesting = false
    await detect(fixture)
    #expect(fixture.surface.bridge.state.remoteIndicator == nil)
    #expect(fixture.state.tabManager.tabs.first?.remoteHosts == [])
  }

  @Test func anUnconfirmedRemoteAgentTurnsStaleAndProvesNothing() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var emitted: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { emitted.append($0) }
    await bindClaude(fixture, probe: probe)
    let fresh = try #require(emitted.last?.remote)
    #expect(fresh.hostLabel == "onevcat@mini.local")
    #expect(fresh.correlation == .correlated)
    #expect(!fresh.isStale)
    #expect(fresh.lastConfirmedAt == nil)

    // Eleven seconds without a confirming snapshot (the host stopped answering).
    await detect(fixture, now: Date().addingTimeInterval(11))
    let stale = try #require(emitted.last?.remote)
    #expect(stale.isStale)
    #expect(stale.lastConfirmedAt != nil)
    // The entry keeps its agent and last state.
    #expect(emitted.last?.agent == .claude)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
    let condition = AgentConditionSnapshot(
      agent: emitted.last, signal: nil, revision: 1, isLive: true, signals: .empty)
    #expect(AgentConditionEvidence.normalizedState(condition) == AgentConditionEvidence.unavailableState)
    #expect(
      !AgentConditionEvidence.detectorReports(.idle, normalizedState: AgentConditionEvidence.normalizedState(condition))
    )
    #expect(AgentConditionEvidence.idleVerdict(for: condition) == .busy(AgentConditionEvidence.unavailableState))
    #expect(
      !AgentConditionEvidence.heuristicMatches(
        condition: .exit, snapshot: condition, normalizedState: AgentConditionEvidence.unavailableState,
        baseline: AgentConditionEvidence.Baseline(snapshot: condition)))

    // A confirming snapshot makes it fresh again.
    await deliver(fixture, snapshot(2, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude")))
    await detect(fixture)
    #expect(emitted.last?.remote?.isStale == false)
  }

  @Test func freshnessCountsFromTheSnapshotsAcquisition() async {
    var clock: TimeInterval = 100
    let source = FakeRemoteSource()
    let surfaceID = UUID()
    let tracker = RemotePaneTracker(
      surfaceID: surfaceID, ssh: LocalProcessGeneration(pid: 1, startedAt: Date()),
      invocation: .supported(SSHConnectionRecipe(destination: "mini")), source: source.source,
      uptime: { clock }, onSnapshot: {})
    tracker.start()
    await settle { source.recipes.count == 1 }
    // Acquired at 100, read by a tick at 104.
    let acquired = RemoteProbeSnapshot(
      connection: source.connection, connectionEpoch: 0, sequence: 1, startedAt: 100, finishedAt: 104,
      outcome: .complete,
      report: RemoteProbeReport(
        operatingSystem: .linux, bootID: "boot",
        sessions: [
          RemoteProbeSession(
            paneID: surfaceID, anchorPID: 100, tty: "/dev/pts/0", foregroundProcessGroupID: 200,
            processes: [remoteProcess(200, name: "claude")])
        ]))
    source.push(acquired)
    await settle { tracker.latest?.sequence == 1 }
    clock = 104
    let read = Date()
    let observation = tracker.observe(active: true, now: read)
    #expect(observation.identified?.agent == .claude)
    // Seven seconds after the read is eleven after the acquisition: stale.
    #expect(observation.context(now: read.addingTimeInterval(7)).isStale)
    #expect(!observation.context(now: read.addingTimeInterval(5)).isStale)
  }

  @Test func aWithdrawnRootOverAnUnknownScreenKeepsTheRemoteEntry() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var removed: [UUID] = []
    fixture.state.onAgentEntryRemoved = { removed.append($0) }
    probe.job = sshJob
    await detect(fixture, screen: .unknown)
    await settle { fixture.source.recipes.count == 1 }
    fixture.state.handleProgramStatus(
      GhosttyProgramStatusReport(state: .idle, kind: nil, id: "", app: "claude-code"), surfaceID: fixture.surfaceID)
    await deliver(fixture, snapshot(1, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude")))
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .idle)
    // The root is withdrawn; no snapshot has proven the agent gone.
    fixture.state.handleProgramStatus(
      GhosttyProgramStatusReport(state: .clear, kind: nil, id: "", app: "claude-code"), surfaceID: fixture.surfaceID)
    await detect(fixture, screen: .unknown)
    await detect(fixture, screen: .unknown)
    #expect(removed.isEmpty)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
    // The state is unknown again, not the withdrawn root's: it stays listed and proves nothing.
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.remote?.isStateKnown == false)
  }

  /// The condition view of the pane's published entry.
  private func condition(_ fixture: Fixture, entries: [ActiveAgentEntry]) -> AgentConditionSnapshot {
    AgentConditionSnapshot(
      agent: entries.last { $0.surfaceID == fixture.surfaceID }, signal: nil, revision: 1, isLive: true,
      signals: .empty)
  }

  @Test func aRemoteAgentWithAnUnknownStateIsListedButSatisfiesNoCondition() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var emitted: [ActiveAgentEntry] = []
    var removed: [UUID] = []
    fixture.state.onAgentEntryChanged = { emitted.append($0) }
    fixture.state.onAgentEntryRemoved = { removed.append($0) }
    probe.job = sshJob
    await detect(fixture, screen: .unknown)
    await settle { fixture.source.recipes.count == 1 }
    // A correlated agent at an unrecognized startup screen, without OSC records.
    await deliver(fixture, snapshot(1, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude")))
    await detect(fixture, screen: .unknown)
    let entry = try #require(emitted.last)
    #expect(entry.agent == .claude)
    #expect(entry.remote?.isStateKnown == false)
    let fresh = condition(fixture, entries: emitted)
    #expect(AgentConditionEvidence.normalizedState(fresh) == "unknown")
    #expect(
      !AgentConditionEvidence.heuristicMatches(
        condition: .exit, snapshot: fresh, normalizedState: "unknown", baseline: .init(snapshot: fresh)))
    // Stale later: still listed, still nothing.
    await detect(fixture, screen: .unknown, now: Date().addingTimeInterval(11))
    #expect(removed.isEmpty)
    let stale = condition(fixture, entries: emitted)
    #expect(AgentConditionEvidence.normalizedState(stale) == AgentConditionEvidence.unavailableState)
    #expect(
      !AgentConditionEvidence.heuristicMatches(
        condition: .exit, snapshot: stale, normalizedState: AgentConditionEvidence.unavailableState,
        baseline: .init(snapshot: stale)))
  }

  @Test func aPredecessorsBlockedStateNeverProvesTheSuccessorBlocked() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var emitted: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { emitted.append($0) }
    probe.job = sshJob
    await detect(fixture, screen: .unknown)
    await settle { fixture.source.recipes.count == 1 }
    fixture.state.handleProgramStatus(
      GhosttyProgramStatusReport(state: .blocked, kind: nil, id: "", app: "claude-code"),
      surfaceID: fixture.surfaceID)
    await deliver(fixture, snapshot(1, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude")))
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .blocked)
    // A successor replaced it between snapshots; its screen is not recognized yet.
    await deliver(fixture, snapshot(2, pane: fixture.surfaceID, foreground: remoteProcess(300, name: "claude")))
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == remoteRef(300))
    let successor = condition(fixture, entries: emitted)
    #expect(AgentConditionEvidence.normalizedState(successor) == "unknown")
    #expect(
      !AgentConditionEvidence.detectorReports(
        .blocked, normalizedState: AgentConditionEvidence.normalizedState(successor)))
    // A withdrawn Blocked root over an unknown screen proves nothing either.
    fixture.state.handleProgramStatus(
      GhosttyProgramStatusReport(state: .blocked, kind: nil, id: "", app: "claude-code"),
      surfaceID: fixture.surfaceID)
    await detect(fixture, screen: .unknown)
    fixture.state.handleProgramStatus(
      GhosttyProgramStatusReport(state: .clear, kind: nil, id: "", app: "claude-code"), surfaceID: fixture.surfaceID)
    await detect(fixture, screen: .unknown)
    #expect(AgentConditionEvidence.normalizedState(condition(fixture, entries: emitted)) == "unknown")
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
    probe.job = shellJob
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

  @Test func aFailedConnectionIsRetriedOnTheNextWake() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    fixture.source.failNext(1)
    probe.job = sshJob
    await detect(fixture)
    await settle { fixture.source.attempts == 1 }
    let tracker = try #require(fixture.state.remotePaneTrackers[fixture.surfaceID])
    await settle { tracker.correlation == .probeUnavailable(nil) }
    // A key press or report wakes the pane: the connection is tried again at once.
    tracker.requestSoon()
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    #expect(fixture.source.attempts == 2)
    await deliver(fixture, snapshot(1, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude")))
    await detect(fixture)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == remoteRef(200))
  }

  @Test func connectionRetriesBackOffWithoutAWake() async throws {
    var clock: TimeInterval = 100
    let source = FakeRemoteSource()
    source.failNext(3)
    let tracker = RemotePaneTracker(
      surfaceID: UUID(), ssh: LocalProcessGeneration(pid: 1, startedAt: Date()),
      invocation: .supported(SSHConnectionRecipe(destination: "mini")), source: source.source,
      uptime: { clock }, onSnapshot: {})
    tracker.start()
    await settle { source.attempts == 1 }
    for _ in 0..<20 { await Task.yield() }
    _ = tracker.observe(active: true, now: Date())
    #expect(source.attempts == 1)
    clock += 1
    _ = tracker.observe(active: true, now: Date())
    await settle { source.attempts == 2 }
    for _ in 0..<20 { await Task.yield() }
    // The next attempt waits twice as long.
    clock += 1
    _ = tracker.observe(active: true, now: Date())
    for _ in 0..<20 { await Task.yield() }
    #expect(source.attempts == 2)
    clock += 1
    _ = tracker.observe(active: true, now: Date())
    await settle { source.attempts == 3 }
    // Retiring stops any further attempt.
    tracker.retire()
    clock += 100
    _ = tracker.observe(active: true, now: Date())
    for _ in 0..<20 { await Task.yield() }
    #expect(source.attempts == 3)
  }

  private var sshGeneration: LocalProcessGeneration {
    LocalProcessGeneration(pid: getpid(), startedAt: ProcessDetection.processStartDate(pid: getpid()) ?? .distantPast)
  }

  private func report(_ state: GhosttyProgramStatusReport.State, app: String = "claude-code")
    -> GhosttyProgramStatusReport
  {
    GhosttyProgramStatusReport(state: state, kind: nil, id: "", app: app)
  }

  @Test func aVerifiedProducerBindsAnUnprobedPaneWithoutARemotePid() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var emitted: [ActiveAgentEntry] = []
    var removed: [UUID] = []
    fixture.state.onAgentEntryChanged = { emitted.append($0) }
    fixture.state.onAgentEntryRemoved = { removed.append($0) }
    fixture.source.failNext(100)
    probe.job = sshJob
    await detect(fixture)
    let tracker = try #require(fixture.state.remotePaneTrackers[fixture.surfaceID])
    await settle { tracker.correlation == .probeUnavailable(nil) }

    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)
    await detect(fixture)
    let pane = fixture.state.surfaceAgentStates[fixture.surfaceID]
    #expect(pane?.agentProcess == .unprobedRemote(sshGeneration))
    #expect(pane?.decision?.reason.identifier == "osc.working")
    let entry = try #require(emitted.last)
    #expect(entry.remote?.isUnprobed == true)
    #expect(entry.remote?.isStale == false)
    #expect(pane?.session == nil)

    // A withdrawal or quiet producer never releases it; the observation turns stale instead.
    fixture.state.handleProgramStatus(report(.clear), surfaceID: fixture.surfaceID)
    await detect(fixture, now: Date().addingTimeInterval(11))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == .unprobedRemote(sshGeneration))
    #expect(removed.isEmpty)
    #expect(emitted.last?.remote?.isStale == true)
    // Only the `ssh` exit releases it.
    probe.job = shellJob
    await detect(fixture)
    #expect(removed == [fixture.surfaceID])
  }

  @Test func aLaterVerifiedProducerReplacesTheUnprobedAgent() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var emitted: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { emitted.append($0) }
    fixture.source.failNext(100)
    probe.job = sshJob
    await detect(fixture, screen: .unknown)
    let tracker = try #require(fixture.state.remotePaneTrackers[fixture.surfaceID])
    await settle { tracker.correlation == .probeUnavailable(nil) }
    fixture.state.handleProgramStatus(report(.idle), surfaceID: fixture.surfaceID)
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
    // Claude exits; Pi starts in the same `ssh` and reports.
    fixture.state.handleProgramStatus(report(.clear), surfaceID: fixture.surfaceID)
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
    fixture.state.handleProgramStatus(report(.working, app: "pi"), surfaceID: fixture.surfaceID)
    await detect(fixture, screen: .unknown)
    let pane = fixture.state.surfaceAgentStates[fixture.surfaceID]
    #expect(pane?.detectedAgent == .pi)
    #expect(pane?.agentProcess == .unprobedRemote(sshGeneration))
    #expect(pane?.decision?.reason.identifier == "osc.working")
    #expect(emitted.last?.remote?.isStale == false)
  }

  @Test func aLocalAgentBetweenSuspendAndResumeNeverBindsAnUnprobedPane() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    fixture.source.failNext(100)
    probe.job = sshJob
    await detect(fixture, screen: .unknown)
    await settle { fixture.source.attempts == 1 }
    // Ctrl-Z: a local Pi runs and leaves an idle root.
    probe.job = ForegroundJob(
      processGroupID: getpid(),
      processes: [ForegroundProcess(pid: getpid(), parentProcessID: 1, name: "pi", argv0: "pi", cmdline: "pi")])
    fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID] = WorktreeTerminalState.AgentScreenScan(
      agent: .pi, text: "", detection: AgentScreenDetection(state: .idle, reason: .legacyDetector))
    _ = await fixture.state.detectAgentState(
      for: fixture.surface, tabId: fixture.tabID, resolveSession: noSession, now: Date())
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == .local(getpid()))
    // Its last root arrives after its last local poll; then it stops without a clear.
    fixture.state.handleProgramStatus(report(.idle, app: "pi"), surfaceID: fixture.surfaceID)
    // `fg`: the remote side cannot be probed and sends nothing new.
    probe.job = sshJob
    await detect(fixture, screen: .unknown)
    let tracker = try #require(fixture.state.remotePaneTrackers[fixture.surfaceID])
    await settle { tracker.correlation == .probeUnavailable(nil) }
    await detect(fixture, screen: .unknown)
    // The local Pi may still be inside its local presence hold, but its record never
    // becomes a remote agent.
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess != .unprobedRemote(sshGeneration))
    // A report from the remote side after the resume binds.
    fixture.state.handleProgramStatus(report(.blocked), surfaceID: fixture.surfaceID)
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == .unprobedRemote(sshGeneration))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .blocked)
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .blocked)
  }

  @Test func aDegradedReacquisitionKeepsTheRetainedSuccessorFence() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    probe.job = sshJob
    await detect(fixture, screen: .unknown)
    await settle { fixture.source.recipes.count == 1 }
    // Claude reports, then the probe identifies a successor (Pi) whose fence excludes it.
    fixture.state.handleProgramStatus(report(.idle), surfaceID: fixture.surfaceID)
    await deliver(fixture, snapshot(1, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude")))
    await detect(fixture, screen: .unknown)
    await deliver(fixture, snapshot(2, pane: fixture.surfaceID, foreground: remoteProcess(300, name: "pi")))
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .pi)
    // Close and undo: the new tracker for the same `ssh` cannot connect.
    fixture.state.retireRemotePaneTracker(surfaceID: fixture.surfaceID)
    fixture.source.failNext(100)
    await detect(fixture, screen: .unknown)
    let tracker = try #require(fixture.state.remotePaneTrackers[fixture.surfaceID])
    await settle { tracker.correlation == .probeUnavailable(nil) }
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess != .unprobedRemote(sshGeneration))
    // A report after the reacquisition binds.
    fixture.state.handleProgramStatus(report(.working, app: "pi"), surfaceID: fixture.surfaceID)
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == .unprobedRemote(sshGeneration))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .pi)
    // The report that bound the agent also decides its state, now and on later ticks.
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.decision?.reason.identifier == "osc.working")
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .working)
  }

  @Test func anUndoneCloseRestoresAQuietUnprobedBinding() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var emitted: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { emitted.append($0) }
    fixture.source.failNext(100)
    probe.job = sshJob
    await detect(fixture, screen: .unknown)
    var tracker = try #require(fixture.state.remotePaneTrackers[fixture.surfaceID])
    await settle { tracker.correlation == .probeUnavailable(nil) }
    fixture.state.handleProgramStatus(report(.blocked), surfaceID: fixture.surfaceID)
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == .unprobedRemote(sshGeneration))
    // Close (retained for undo) and undo; the producer stays quiet.
    fixture.state.retireRemotePaneTracker(surfaceID: fixture.surfaceID)
    fixture.state.surfaceAgentStates[fixture.surfaceID] = PaneAgentState(lastChangedAt: Date())
    await detect(fixture, screen: .unknown)
    tracker = try #require(fixture.state.remotePaneTrackers[fixture.surfaceID])
    await settle { tracker.correlation == .probeUnavailable(nil) }
    await detect(fixture, screen: .unknown)
    let pane = fixture.state.surfaceAgentStates[fixture.surfaceID]
    #expect(pane?.agentProcess == .unprobedRemote(sshGeneration))
    #expect(pane?.detectedAgent == .claude)
    #expect(pane?.state == .blocked)
    #expect(emitted.last?.remote?.isStale == false)
  }

  @Test func aProbeGapRightAfterUndoNeverEndsTheForegroundInterval() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    fixture.source.failNext(100)
    probe.job = sshJob
    await detect(fixture, screen: .unknown)
    var tracker = try #require(fixture.state.remotePaneTrackers[fixture.surfaceID])
    await settle { tracker.correlation == .probeUnavailable(nil) }
    fixture.state.handleProgramStatus(report(.blocked), surfaceID: fixture.surfaceID)
    await detect(fixture, screen: .unknown)
    fixture.state.retireRemotePaneTracker(surfaceID: fixture.surfaceID)
    fixture.state.surfaceAgentStates[fixture.surfaceID] = PaneAgentState(lastChangedAt: Date())
    // The first sample after the restore reads no job.
    probe.job = nil
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.remoteFenceHistoryBySurface[fixture.surfaceID]?[sshGeneration]?.leftForeground == false)
    probe.job = sshJob
    await detect(fixture, screen: .unknown)
    tracker = try #require(fixture.state.remotePaneTrackers[fixture.surfaceID])
    await settle { tracker.correlation == .probeUnavailable(nil) }
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == .unprobedRemote(sshGeneration))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .blocked)
  }

  @Test func aProbeGapKeepsTheDegradedConfirmation() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var emitted: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { emitted.append($0) }
    fixture.source.failNext(100)
    probe.job = sshJob
    await detect(fixture, screen: .unknown)
    let tracker = try #require(fixture.state.remotePaneTrackers[fixture.surfaceID])
    await settle { tracker.correlation == .probeUnavailable(nil) }
    fixture.state.handleProgramStatus(report(.idle), surfaceID: fixture.surfaceID)
    await detect(fixture, screen: .unknown)
    #expect(emitted.last?.remote?.isStale == false)
    // A tick whose local probe reads nothing keeps the binding and its fresh confirmation.
    probe.job = nil
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == .unprobedRemote(sshGeneration))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.remote?.isStale == false)
    // Stale only once the report is older than ten seconds.
    await detect(fixture, screen: .unknown, now: Date().addingTimeInterval(11))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.remote?.isStale == true)
    // A newer eligible report during the gap refreshes it.
    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.remote?.isStale == false)
  }

  @Test(arguments: [true, false])
  func switchingBetweenSuspendedSSHClientsKeepsEachForegroundInterval(sampleShell: Bool) async throws {
    // A second real process stands in for the other `ssh` client, so it has a generation.
    let other = Process()
    other.executableURL = URL(fileURLWithPath: "/bin/sleep")
    other.arguments = ["30"]
    try other.run()
    defer { other.terminate() }
    let sshB = ForegroundJob(
      processGroupID: other.processIdentifier,
      processes: [
        ForegroundProcess(
          pid: other.processIdentifier, parentProcessID: 1, name: "ssh", argv0: "ssh", cmdline: "ssh box",
          arguments: ["ssh", "box"])
      ])
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    fixture.source.failNext(100)
    // `ssh` A runs, then is suspended (the shell is in front, sampled or not).
    probe.job = sshJob
    await detect(fixture, screen: .unknown)
    if sampleShell {
      probe.job = shellJob
      await detect(fixture, screen: .unknown)
    }
    // `ssh` B runs and its Pi reports; then B is suspended.
    probe.job = sshB
    await detect(fixture, screen: .unknown)
    fixture.state.handleProgramStatus(report(.idle, app: "pi"), surfaceID: fixture.surfaceID)
    if sampleShell {
      probe.job = shellJob
      await detect(fixture, screen: .unknown)
    }
    // A is in front again and cannot be probed: B's report is not A's agent.
    probe.job = sshJob
    await detect(fixture, screen: .unknown)
    let tracker = try #require(fixture.state.remotePaneTrackers[fixture.surfaceID])
    #expect(tracker.ssh == sshGeneration)
    await settle { tracker.correlation == .probeUnavailable(nil) }
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess != .unprobedRemote(sshGeneration))
    // A report from A's own interval binds.
    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == .unprobedRemote(sshGeneration))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude)
  }

  @Test func aProbeGapKeepsTheRemoteBinding() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var removed: [UUID] = []
    fixture.state.onAgentEntryRemoved = { removed.append($0) }
    await bindClaude(fixture, probe: probe)
    // The local probe reads nothing for a tick.
    probe.job = nil
    await detect(fixture)
    probe.job = sshJob
    await detect(fixture)
    #expect(removed.isEmpty)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == remoteRef(200))
    #expect(fixture.source.recipes.count == 1)
  }

  @Test func unprobedBindingNeedsAVerifiedReportFromThisSSH() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    fixture.source.failNext(100)
    probe.job = sshJob
    await detect(fixture)
    let tracker = try #require(fixture.state.remotePaneTrackers[fixture.surfaceID])
    await settle { tracker.correlation == .probeUnavailable(nil) }
    // A root that arrived before this `ssh` started belongs to something else.
    let sshStart = sshGeneration.startedAt
    fixture.state.handleProgramStatus(report(.idle), surfaceID: fixture.surfaceID, now: sshStart.addingTimeInterval(-1))
    await detect(fixture)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)
    // An unverified producer never binds.
    fixture.state.programStatusSupportForTesting = { _ in .unverified }
    fixture.state.handleProgramStatus(report(.idle), surfaceID: fixture.surfaceID)
    await detect(fixture)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)
  }

  @Test func aProbedSessionSupersedesTheUnprobedBinding() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    probe.job = sshJob
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    // Unmapped: the host is reachable but no session carries this pane's id.
    await deliver(fixture, snapshot(1, pane: UUID(), foreground: remoteProcess(200, name: "claude")))
    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID)
    await detect(fixture)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == .unprobedRemote(sshGeneration))
    // The pane is mapped now and shows the agent: the probed reference takes over and keeps
    // the report the degraded binding accepted.
    await deliver(fixture, snapshot(2, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude")))
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == remoteRef(200))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.decision?.reason.identifier == "osc.working")
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

struct RemoteAgentDetectionSwitchTests {
  @Test func detectionIsOnUnlessTurnedOff() throws {
    let defaults = try #require(UserDefaults(suiteName: "RemoteAgentDetectionSwitchTests-\(UUID().uuidString)"))
    #expect(RemoteAgentDetection.isEnabled(environment: [:], defaults: defaults))
    #expect(!RemoteAgentDetection.isEnabled(environment: ["PROWL_REMOTE_AGENT_DETECTION": "0"], defaults: defaults))
    defaults.set(false, forKey: RemoteAgentDetection.defaultsKey)
    #expect(!RemoteAgentDetection.isEnabled(environment: [:], defaults: defaults))
    // The environment wins over the default, both ways.
    #expect(RemoteAgentDetection.isEnabled(environment: ["PROWL_REMOTE_AGENT_DETECTION": "1"], defaults: defaults))
  }
}

struct RemoteAgentContextTests {
  @Test func stalenessFollowsTheLastConfirmation() {
    let now = Date(timeIntervalSince1970: 1_000)
    let key = ConnectionKey(user: "dev", hostname: "box")
    let fresh = RemoteAgentContext(
      connection: key, correlation: .correlated, confirmedAt: now.addingTimeInterval(-9), now: now)
    #expect(!fresh.isStale)
    // A steady stream of confirmations never changes a fresh context.
    #expect(
      fresh
        == RemoteAgentContext(
          connection: key, correlation: .correlated, confirmedAt: now.addingTimeInterval(-1), now: now))
    let stale = RemoteAgentContext(
      connection: key, correlation: .unmapped, confirmedAt: now.addingTimeInterval(-11), now: now)
    #expect(stale.isStale)
    #expect(stale.lastConfirmedAt == now.addingTimeInterval(-11))
    #expect(RemoteAgentContext(connection: nil, correlation: .pending, confirmedAt: nil, now: now).isStale)
    #expect(stale.hostLabel == "dev@box")
  }
}
