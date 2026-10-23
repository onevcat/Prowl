import AppKit
import Clocks
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
  /// A fixed host uptime: freshness windows count from it, so a slow run never makes a
  /// snapshot stale between the test's steps.
  private static let uptime: TimeInterval = 1_000

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
    state.remoteUptimeForTesting = { Self.uptime }
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

  /// The `ssh` that a remote folder's pane types: its arguments carry the launch's nonce.
  private var launchSSHJob: ForegroundJob {
    let arguments = [
      "/usr/bin/ssh", "-t", "--", "mini", "exec", "sh", "/home/dev/.cache/prowl/launch/0123456789abcdef/launch.sh",
    ]
    return ForegroundJob(
      processGroupID: getpid(),
      processes: [
        ForegroundProcess(
          pid: getpid(), parentProcessID: 1, name: "ssh", argv0: "ssh", cmdline: arguments.joined(separator: " "),
          arguments: arguments)
      ])
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

  private func remoteProcess(
    _ pid: Int32, name: String, start: String = "t1", directory: String = "/home/dev"
  ) -> RemoteProbeProcess {
    RemoteProbeProcess(
      pid: pid, parentPID: 100, processGroupID: pid, startToken: start, elapsedSeconds: 1, name: name,
      arguments: [name], commandLine: name, workingDirectory: directory)
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
    return RemoteProbeSnapshot(
      connection: ConnectionKey(user: "onevcat", hostname: "mini.local"), connectionEpoch: epoch, sequence: sequence,
      startedAt: Self.uptime, finishedAt: Self.uptime, outcome: outcome,
      report: RemoteProbeReport(operatingSystem: .linux, bootID: bootID, sessions: sessions))
  }

  /// A snapshot whose session shows a tmux client (pid 150); its active pane runs `pane`.
  private func tmuxSnapshot(
    _ sequence: UInt64, pane: UUID?, foreground: RemoteProbeProcess, screen: String?, inMode: Bool = false,
    paneID: String = "%0", outcome: RemoteProbeSnapshot.Outcome = .complete, age: TimeInterval = 0
  ) -> RemoteProbeSnapshot {
    let client = remoteProcess(150, name: "tmux")
    var session = RemoteProbeSession(
      paneID: pane, anchorPID: 100, tty: "/dev/pts/0", foregroundProcessGroupID: client.processGroupID,
      processes: [client])
    session.tmux = RemoteProbeTmuxPane(
      clientPID: 150, paneID: paneID, tty: "/dev/pts/3", isInMode: inMode,
      foregroundProcessGroupID: foreground.processGroupID, processes: [foreground], screen: screen,
      isScreenTruncated: false)
    let now = Self.uptime - age
    return RemoteProbeSnapshot(
      connection: ConnectionKey(user: "onevcat", hostname: "mini.local"), connectionEpoch: 0, sequence: sequence,
      startedAt: now, finishedAt: now, outcome: outcome,
      report: RemoteProbeReport(operatingSystem: .linux, bootID: "boot", sessions: [session]))
  }

  /// A complete snapshot whose session shows a tmux client (pid 150) whose server the probe
  /// could not reach.
  private func unreadTmuxSnapshot(_ sequence: UInt64, pane: UUID?) -> RemoteProbeSnapshot {
    let client = remoteProcess(150, name: "tmux")
    var session = RemoteProbeSession(
      paneID: pane, anchorPID: 100, tty: "/dev/pts/0", foregroundProcessGroupID: client.processGroupID,
      processes: [client])
    session.hasUnreadTmuxPane = true
    let now = Self.uptime
    return RemoteProbeSnapshot(
      connection: ConnectionKey(user: "onevcat", hostname: "mini.local"), connectionEpoch: 0, sequence: sequence,
      startedAt: now, finishedAt: now, outcome: .complete,
      report: RemoteProbeReport(operatingSystem: .linux, bootID: "boot", sessions: [session]))
  }

  private func paneIssue(_ fixture: Fixture) -> RemotePaneCorrelation? {
    guard case .connected(_, _, let issue) = fixture.surface.bridge.state.remoteIndicator else { return nil }
    return issue
  }

  private static let workingClaude = "✻ Tempering… (12s · esc to interrupt)\n"

  private static let blockedClaude = """
    ✻ Tempering… (12s · esc to interrupt)
    Do you want to proceed?
    ❯ 1. Yes
      2. No
    Esc to cancel · Tab to amend
    """

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
  private func settle(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
    await waitUntil(sourceLocation: sourceLocation, condition)
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
    // A line break keeps the two sentences apart when VoiceOver reads the help.
    #expect(surface.accessibilityHelp()?.hasPrefix("Pane 1 of 2\ndev@box has no session for this pane.") == true)
    surface.bridge.state.remoteIndicator = .ended(host: "dev@box", endedAt: Date())
    #expect(surface.accessibilityLabel() == "Claude Code, disconnected from dev@box")
    // An old exit is not announced.
    surface.bridge.state.remoteIndicator = .ended(host: "dev@box", endedAt: Date().addingTimeInterval(-10))
    #expect(surface.accessibilityLabel() == "Claude Code")
    surface.bridge.state.remoteIndicator = nil
    #expect(surface.accessibilityHelp() == "Pane 1 of 2")
  }

  @Test func aChangedSpokenRemoteStateIsAnnounced() async throws {
    let (ssh, job) = try spawnSSH()
    defer { if ssh.isRunning { ssh.terminate() } }
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var posts: [NSAccessibility.Notification] = []
    fixture.state.accessibilityPosterForTesting = { _, notification in posts.append(notification) }
    probe.job = job
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    // Healthy, then an issue: two announcements.
    await deliver(fixture, snapshot(1, pane: fixture.surfaceID, foreground: remoteProcess(101, name: "zsh")))
    await detect(fixture)
    #expect(posts == [.titleChanged])
    // The pane's session is gone (neither its id nor its pinned anchor is on the host).
    await deliver(fixture, snapshot(2, pane: nil, foreground: nil, anchor: 999))
    await detect(fixture)
    #expect(posts == [.titleChanged, .titleChanged])
    // An equal sample says nothing new.
    await detect(fixture)
    #expect(posts.count == 2)
    // The `ssh` ends: announced.
    ssh.terminate()
    ssh.waitUntilExit()
    probe.job = shellJob
    await detect(fixture)
    #expect(posts.count == 3)
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

  /// A fixture whose mode comes from the stored consent, with no environment override.
  private func makeConsentFixture(probe: Probe) -> Fixture {
    let fixture = makeFixture(probe: probe)
    fixture.state.remoteAgentDetectionEnabledForTesting = nil
    fixture.state.remoteDetectionEnvironmentForTesting = [:]
    return fixture
  }

  @Test func anUndecidedAnswerAsksOnceAndOpensNoConnection() async {
    let probe = Probe()
    let fixture = makeConsentFixture(probe: probe)
    var asked: [String] = []
    fixture.state.onRemoteAgentConsentNeeded = { surfaceID, destination in
      #expect(surfaceID == fixture.surfaceID)
      asked.append(destination)
    }
    probe.job = sshJob
    await detect(fixture)
    await detect(fixture)
    for _ in 0..<50 { await Task.yield() }

    #expect(asked == ["mini"])
    #expect(fixture.source.attempts == 0)
    #expect(fixture.state.remotePaneTrackers[fixture.surfaceID] == nil)
    #expect(fixture.surface.bridge.state.remoteIndicator == nil)
  }

  @Test func anSSHOutsideTheGrammarDoesNotAsk() async {
    let probe = Probe()
    let fixture = makeConsentFixture(probe: probe)
    var asked: [String] = []
    fixture.state.onRemoteAgentConsentNeeded = { _, destination in asked.append(destination) }
    probe.job = ForegroundJob(
      processGroupID: getpid(),
      processes: [
        ForegroundProcess(
          pid: getpid(), parentProcessID: 1, name: "ssh", argv0: "ssh", cmdline: "ssh -N mini",
          arguments: ["ssh", "-N", "mini"])
      ])
    await detect(fixture)
    #expect(asked.isEmpty)
  }

  @Test(arguments: ["git", "scp", "sftp", "rsync"], [false, true])
  func aTransportSSHNeverAsksOrConnects(tool: String, throughShell: Bool) async {
    let probe = Probe()
    let fixture = makeConsentFixture(probe: probe)
    defer { fixture.state.retireRemotePaneTracker(surfaceID: fixture.surfaceID) }
    var asked: [String] = []
    fixture.state.onRemoteAgentConsentNeeded = { _, destination in asked.append(destination) }
    let toolPID = getpid() + 1
    let shellPID = getpid() + 2
    let command =
      switch tool {
      case "git": "git-upload-pack 'repo.git'"
      case "scp": "scp -t /tmp/file"
      case "sftp": "sftp"
      default: "rsync --server ."
      }
    let arguments = ["ssh", "-o", "SendEnv=GIT_PROTOCOL", "git@git.linecorp.com", command]
    // Read the SSH before its ancestors, including a shell used by GIT_SSH_COMMAND.
    var processes = [
      ForegroundProcess(
        pid: getpid(), parentProcessID: throughShell ? shellPID : toolPID, name: "ssh", argv0: "ssh",
        cmdline: arguments.joined(separator: " "), arguments: arguments)
    ]
    if throughShell {
      processes.append(
        ForegroundProcess(pid: shellPID, parentProcessID: toolPID, name: "sh", argv0: "sh", cmdline: "sh -c ssh"))
    }
    processes.append(
      ForegroundProcess(pid: toolPID, parentProcessID: 1, name: tool, argv0: throughShell ? nil : tool, cmdline: tool))
    probe.job = ForegroundJob(processGroupID: getpid(), processes: processes)

    await detect(fixture)
    #expect(asked.isEmpty)
    #expect(fixture.state.remoteConsentAskedSSHBySurface.isEmpty)
    #expect(fixture.state.remotePaneTrackers[fixture.surfaceID] == nil)

    fixture.state.setRemoteAgentDetectionConsent(.enabled)
    await detect(fixture)
    #expect(fixture.state.remotePaneTrackers[fixture.surfaceID] == nil)
    #expect(fixture.source.attempts == 0)
    #expect(fixture.surface.bridge.state.remoteIndicator == nil)
  }

  @Test(arguments: [
    ["dev@box"], ["-t", "dev@box", "claude"], ["dev@box", "tmux", "attach"], ["-T", "dev@box", "pi"],
  ])
  func aSessionSSHStillAsksAndConnects(arguments: [String]) async {
    let probe = Probe()
    let fixture = makeConsentFixture(probe: probe)
    defer { fixture.state.retireRemotePaneTracker(surfaceID: fixture.surfaceID) }
    var asked: [String] = []
    fixture.state.onRemoteAgentConsentNeeded = { _, destination in asked.append(destination) }
    let shellPID = getpid() + 1
    probe.job = ForegroundJob(
      processGroupID: getpid(),
      processes: [
        ForegroundProcess(
          pid: getpid(), parentProcessID: shellPID, name: "ssh", argv0: "ssh", cmdline: "ssh",
          arguments: ["ssh"] + arguments),
        ForegroundProcess(pid: shellPID, parentProcessID: 1, name: "sh", argv0: "sh", cmdline: "sh"),
      ])

    await detect(fixture)
    #expect(asked == ["dev@box"])
    #expect(fixture.source.attempts == 0)

    fixture.state.setRemoteAgentDetectionConsent(.enabled)
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    #expect(fixture.source.recipes.first?.destination == "dev@box")
  }

  @Test func turningDetectionOnReadsTheOpenSSHWithoutAReconnect() async {
    let probe = Probe()
    let fixture = makeConsentFixture(probe: probe)
    probe.job = sshJob
    await detect(fixture)
    #expect(fixture.source.attempts == 0)

    fixture.state.setRemoteAgentDetectionConsent(.enabled)
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    #expect(fixture.source.recipes.first?.destination == "mini")
    #expect(fixture.state.remoteConsentAskedSSHBySurface.isEmpty)
  }

  /// Review R1 (rounds 1 and 2): a pane whose loop went cold while detection was off, or
  /// while the question waited, has nothing to wake it and no pane state. Turning detection
  /// on must start its loop and publish the remote agent, with no key press or manual tick.
  @Test(arguments: [RemoteAgentDetectionConsent.disabled, .undecided])
  func turningDetectionOnPublishesTheAgentOfAColdSSHPane(before: RemoteAgentDetectionConsent) async {
    let probe = Probe()
    let fixture = makeConsentFixture(probe: probe)
    fixture.state.setRemoteAgentDetectionConsent(before)
    probe.job = sshJob
    await detect(fixture)
    #expect(fixture.source.attempts == 0)
    fixture.state.finishColdAgentDetection(forSurfaceID: fixture.surfaceID)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID] == nil)

    fixture.state.setRemoteAgentDetectionConsent(.enabled)
    await settle { fixture.source.recipes.count == 1 }
    fixture.source.push(snapshot(1, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude")))
    await settle { fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == .claude }
    fixture.state.agentDetectionTasks[fixture.surfaceID]?.cancel()
    fixture.state.retireRemotePaneTracker(surfaceID: fixture.surfaceID)
  }

  @Test func theEnvironmentNeverAsks() async {
    let probe = Probe()
    let fixture = makeConsentFixture(probe: probe)
    fixture.state.remoteDetectionEnvironmentForTesting = ["PROWL_REMOTE_AGENT_DETECTION": "0"]
    var asked = false
    fixture.state.onRemoteAgentConsentNeeded = { _, _ in asked = true }
    probe.job = sshJob
    await detect(fixture)
    #expect(!asked)
    #expect(fixture.source.attempts == 0)
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

  @Test func anUnrelatedTransportInTheJobDoesNotHideTheSessionSSH() {
    let job = ForegroundJob(
      processGroupID: getpid(),
      processes: sshJob.processes + [
        ForegroundProcess(pid: getpid() + 1, parentProcessID: 1, name: "git", argv0: "git", cmdline: "git fetch")
      ])
    let ssh = WorktreeTerminalState.foregroundSSH(job)
    #expect(ssh?.generation.pid == getpid())
    #expect(ssh?.arguments == ["-p", "2222", "mini"])
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

    // A base past the real clock: the report and the ticks after it share one time, so a
    // slow run never ages the report (a tick fences at `max(now, Date())`).
    let later = Date().addingTimeInterval(3_600)
    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID, now: later)
    await detect(fixture, now: later)
    let pane = fixture.state.surfaceAgentStates[fixture.surfaceID]
    #expect(pane?.agentProcess == .unprobedRemote(sshGeneration))
    #expect(pane?.decision?.reason.identifier == "osc.working")
    let entry = try #require(emitted.last)
    #expect(entry.remote?.isUnprobed == true)
    #expect(entry.remote?.isStale == false)
    #expect(pane?.session == nil)

    // A withdrawal or quiet producer never releases it; the observation turns stale instead.
    fixture.state.handleProgramStatus(report(.clear), surfaceID: fixture.surfaceID, now: later)
    await detect(fixture, now: later.addingTimeInterval(11))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == .unprobedRemote(sshGeneration))
    #expect(removed.isEmpty)
    #expect(emitted.last?.remote?.isStale == true)
    // Only the `ssh` exit releases it.
    probe.job = shellJob
    await detect(fixture, now: later)
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
    // A base past the real clock: the report and the ticks after it share one time, so a
    // slow run never ages the report (a tick fences at `max(now, Date())`).
    let later = Date().addingTimeInterval(3_600)
    fixture.state.handleProgramStatus(report(.blocked), surfaceID: fixture.surfaceID, now: later)
    await detect(fixture, screen: .unknown, now: later)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == .unprobedRemote(sshGeneration))
    // Close (retained for undo) and undo; the producer stays quiet.
    fixture.state.retireRemotePaneTracker(surfaceID: fixture.surfaceID)
    fixture.state.surfaceAgentStates[fixture.surfaceID] = PaneAgentState(lastChangedAt: Date())
    await detect(fixture, screen: .unknown, now: later)
    tracker = try #require(fixture.state.remotePaneTrackers[fixture.surfaceID])
    await settle { tracker.correlation == .probeUnavailable(nil) }
    await detect(fixture, screen: .unknown, now: later)
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
    // A base past the real clock: the report and the ticks after it share one time, so a
    // slow run never ages the report (a tick fences at `max(now, Date())`).
    let later = Date().addingTimeInterval(3_600)
    fixture.state.handleProgramStatus(report(.idle), surfaceID: fixture.surfaceID, now: later)
    await detect(fixture, screen: .unknown, now: later)
    #expect(emitted.last?.remote?.isStale == false)
    // A tick whose local probe reads nothing keeps the binding and its fresh confirmation.
    probe.job = nil
    await detect(fixture, screen: .unknown, now: later)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == .unprobedRemote(sshGeneration))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.remote?.isStale == false)
    // Stale only once the report is older than ten seconds.
    await detect(fixture, screen: .unknown, now: later.addingTimeInterval(11))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.remote?.isStale == true)
    // A newer eligible report during the gap refreshes it.
    fixture.state.handleProgramStatus(report(.working), surfaceID: fixture.surfaceID, now: later.addingTimeInterval(12))
    await detect(fixture, screen: .unknown, now: later.addingTimeInterval(12))
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

  @Test func anAgentInTmuxIsIdentifiedByTheMappingAndReadFromTheCapture() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    // The local screen is the tmux client's: it shows nothing an agent rule matches.
    fixture.surface.bridge.activeTextForTesting = "[spike] 0:claude*"
    probe.job = sshJob
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    await deliver(
      fixture,
      tmuxSnapshot(
        1, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude"), screen: Self.blockedClaude))
    await detect(fixture, screen: .unknown)
    let pane = fixture.state.surfaceAgentStates[fixture.surfaceID]
    #expect(pane?.agentProcess == remoteRef(200))
    #expect(pane?.detectedAgent == .claude)
    #expect(pane?.state == .blocked)
    #expect(fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID]?.text == Self.blockedClaude)
  }

  @Test func copyModeKeepsAndAPaneSwitchReleasesTheTmuxAgent() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    probe.job = sshJob
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    let claude = remoteProcess(200, name: "claude")
    await deliver(fixture, tmuxSnapshot(1, pane: fixture.surfaceID, foreground: claude, screen: Self.blockedClaude))
    await detect(fixture, screen: .unknown)
    // Copy mode: the same pane and agent, so nothing changes.
    await deliver(
      fixture, tmuxSnapshot(2, pane: fixture.surfaceID, foreground: claude, screen: Self.blockedClaude, inMode: true))
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == remoteRef(200))
    // The client switched to a pane with a shell: two complete snapshots release the agent.
    for sequence in UInt64(3)...4 {
      await deliver(
        fixture,
        tmuxSnapshot(
          sequence, pane: fixture.surfaceID, foreground: remoteProcess(300, name: "zsh"), screen: "$ ", paneID: "%1"))
      await detect(fixture, screen: .unknown)
    }
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)
  }

  /// Binds a working Claude inside tmux while the local screen (the client's view) shows a
  /// blocked prompt, which must never decide.
  private func bindWorkingTmuxClaude(_ fixture: Fixture, probe: Probe) async {
    fixture.surface.bridge.activeTextForTesting = Self.blockedClaude
    probe.job = sshJob
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    await deliver(
      fixture,
      tmuxSnapshot(
        1, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude"), screen: Self.workingClaude))
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .working)
  }

  @Test func aMissingCaptureNeverFallsBackToTheClientScreen() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await bindWorkingTmuxClaude(fixture, probe: probe)
    // A failed probe, then a partial one that kept the mapping and process but lost the screen.
    await deliver(fixture, snapshot(2, pane: nil, foreground: nil, outcome: .failed(.unreachable)))
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .working)
    let partial = tmuxSnapshot(
      3, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude"), screen: nil, outcome: .partial)
    await deliver(fixture, partial)
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .working)
    #expect(fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID]?.text == Self.workingClaude)
  }

  @Test func anUnreachableTmuxServerIsAGapAndNotAnExit() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await bindWorkingTmuxClaude(fixture, probe: probe)
    // The server's socket went away (or its binary no longer speaks to it): the session's
    // foreground is only the client, which says nothing about the agent in the pane.
    for sequence in UInt64(2)...4 {
      await deliver(fixture, unreadTmuxSnapshot(sequence, pane: fixture.surfaceID))
      await detect(fixture, screen: .unknown)
    }
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == remoteRef(200))
    #expect(fixture.state.remotePaneTrackers[fixture.surfaceID]?.correlation == .tmuxUnreachable)
    // The pane says why its agents are not read.
    #expect(paneIssue(fixture) == .tmuxUnreachable)
    // The local screen (the client's view) never stands in.
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .working)
    // The server is back.
    await deliver(
      fixture,
      tmuxSnapshot(
        5, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude"), screen: Self.blockedClaude))
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.remotePaneTrackers[fixture.surfaceID]?.correlation == .correlated)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .blocked)
  }

  @Test func aTmuxClientOfAnUnreachableServerNeverBindsAnAgent() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    fixture.surface.bridge.activeTextForTesting = Self.workingClaude
    probe.job = sshJob
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    await deliver(fixture, unreadTmuxSnapshot(1, pane: fixture.surfaceID))
    await detect(fixture, screen: .working)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)
    #expect(paneIssue(fixture) == .tmuxUnreachable)
    #expect(fixture.state.remotePaneTrackers[fixture.surfaceID]?.allowsUnprobedBinding == false)
  }

  @Test func anOldCaptureLeavesTheStateUnknown() async throws {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    var clock: TimeInterval = 1_000
    fixture.state.remoteUptimeForTesting = { clock }
    var emitted: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { emitted.append($0) }
    fixture.surface.bridge.activeTextForTesting = "$ "
    probe.job = sshJob
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    let claude = remoteProcess(200, name: "claude")
    func snapshot(_ sequence: UInt64, screen: String?) -> RemoteProbeSnapshot {
      let base = tmuxSnapshot(
        sequence, pane: fixture.surfaceID, foreground: claude, screen: screen,
        outcome: screen == nil ? .partial : .complete)
      return RemoteProbeSnapshot(
        connection: base.connection, connectionEpoch: 0, sequence: sequence, startedAt: clock, finishedAt: clock,
        outcome: base.outcome, report: base.report)
    }
    await deliver(fixture, snapshot(1, screen: Self.blockedClaude))
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .blocked)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.remote?.isStateKnown == true)
    // Twelve seconds of probes that confirm the process but lose the screen.
    clock = 1_012
    await deliver(fixture, snapshot(2, screen: nil))
    await detect(fixture, screen: .unknown)
    let pane = try #require(fixture.state.surfaceAgentStates[fixture.surfaceID])
    #expect(pane.remote?.isStale == false)
    #expect(pane.remote?.isStateKnown == false)
    #expect(emitted.last?.remote?.isStateKnown == false)
    #expect(fixture.state.lastAgentScreenScanBySurface[fixture.surfaceID]?.detection.state == .unknown)
    // A fresh capture of the agent's pane recovers it.
    await deliver(fixture, snapshot(3, screen: Self.workingClaude))
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.remote?.isStateKnown == true)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .working)
  }

  @Test func aDetachedClientKeepsTheRetainedAgentOnItsOwnCapture() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await bindWorkingTmuxClaude(fixture, probe: probe)
    // The user detached: the session shows the remote shell, and the local screen with it.
    fixture.surface.bridge.activeTextForTesting = "$ "
    await deliver(fixture, snapshot(2, pane: fixture.surfaceID, foreground: remoteProcess(101, name: "zsh")))
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == remoteRef(200))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .working)
    await deliver(fixture, snapshot(3, pane: fixture.surfaceID, foreground: remoteProcess(101, name: "zsh")))
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)
  }

  @Test func anotherPanesCaptureNeverDescribesTheRetainedAgent() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    await bindWorkingTmuxClaude(fixture, probe: probe)
    // The client switched to a shell pane; the presence rule still holds Claude for one
    // more snapshot, and the shell's screen is not Claude's.
    await deliver(
      fixture,
      tmuxSnapshot(2, pane: fixture.surfaceID, foreground: remoteProcess(300, name: "zsh"), screen: "$ ", paneID: "%1"))
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.agentProcess == remoteRef(200))
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.state == .working)
    await deliver(
      fixture,
      tmuxSnapshot(3, pane: fixture.surfaceID, foreground: remoteProcess(300, name: "zsh"), screen: "$ ", paneID: "%1"))
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.detectedAgent == nil)
  }

  @Test func aChangedLocalScreenInTmuxAsksForACapture() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    probe.job = sshJob
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    await deliver(
      fixture,
      tmuxSnapshot(
        1, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude"), screen: Self.blockedClaude))
    fixture.surface.bridge.activeTextForTesting = "frame 1"
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.tmuxLocalScreenHashBySurface[fixture.surfaceID] == "frame 1".hashValue)
    // Out of tmux, the local screen is the agent's screen again.
    await deliver(fixture, snapshot(2, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude")))
    await detect(fixture, screen: .unknown)
    #expect(fixture.state.tmuxLocalScreenHashBySurface[fixture.surfaceID] == nil)
  }

  @Test func screenChangeRefreshesKeepTheirSpacing() async {
    var clock: TimeInterval = 100
    let source = FakeRemoteSource()
    let tracker = RemotePaneTracker(
      surfaceID: UUID(), ssh: LocalProcessGeneration(pid: 1, startedAt: Date()),
      invocation: .supported(SSHConnectionRecipe(destination: "mini")), source: source.source,
      uptime: { clock }, onSnapshot: {})
    tracker.start()
    await settle { source.recipes.count == 1 }
    let opened = source.refreshes
    clock = 101
    tracker.requestRefreshForScreenChange()
    await settle { source.refreshes == opened + 1 }
    // Sustained output: a change every 0.1 s asks again only after the spacing.
    clock = 101.1
    tracker.requestRefreshForScreenChange()
    clock = 101.2
    tracker.requestRefreshForScreenChange()
    clock = 101.3
    tracker.requestRefreshForScreenChange()
    await settle { source.refreshes == opened + 2 }
    for _ in 0..<50 { await Task.yield() }
    #expect(source.refreshes == opened + 2)
    tracker.retire()
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

  private static func origin(recipe: SSHConnectionRecipe) -> RemoteLaunchOrigin {
    RemoteLaunchOrigin(
      hostProfileID: UUID(), alias: "mini", recipe: recipe, nonce: "0123456789abcdef", hasFirstCommand: false,
      launchedAt: Date())
  }

  /// A pane that Prowl opened in a remote folder (docs-ai 084 C3b) needs no consent, uses the
  /// stored recipe instead of the `ssh` arguments, and shows the profile's alias. Once its
  /// `ssh` ended, a later `ssh` in the pane is the user's own and asks.
  @Test func aRemoteFolderPaneUsesItsStoredRecipeWithoutConsent() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    fixture.state.remoteAgentDetectionEnabledForTesting = nil
    fixture.state.remoteDetectionEnvironmentForTesting = [:]
    var asked: [String] = []
    fixture.state.onRemoteAgentConsentNeeded = { _, destination in asked.append(destination) }
    let stored = SSHConnectionRecipe(destination: "dev@mini.local", options: ["-p", "22"])
    fixture.state.remoteLaunchOriginBySurface[fixture.surfaceID] = Self.origin(recipe: stored)

    probe.job = launchSSHJob
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    await deliver(fixture, snapshot(1, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude")))
    await detect(fixture)

    #expect(asked.isEmpty)
    #expect(fixture.source.recipes == [stored])
    #expect(fixture.surface.bridge.state.remoteIndicator?.connectedHost == "mini")
    #expect(fixture.state.surfaceAgentStates[fixture.surfaceID]?.remote?.hostLabel == "mini")
    probe.job = shellJob
    await detect(fixture)
    probe.job = sshJob
    await detect(fixture)
    #expect(asked == ["mini"])
  }

  /// A remote agent's entry and directory are the host's (docs-ai 084 C4), not the pane's
  /// local one.
  @Test func aRemoteAgentWorksInItsHostDirectory() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    probe.job = sshJob
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    await deliver(
      fixture,
      snapshot(1, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "claude", directory: "/srv/app/api")))
    await detect(fixture)

    #expect(fixture.state.remotePaneTrackers[fixture.surfaceID]?.agentWorkingDirectory == "/srv/app/api")
    #expect(fixture.state.activeAgentWorkingDirectory(surfaceID: fixture.surfaceID)?.path == "/srv/app/api")
  }

  /// A remote split starts where its anchor pane is on the host: after a fresh snapshot,
  /// else the last known directory when none comes in time (docs-ai 084 C4).
  @Test func aRemoteSplitStartsWhereItsAnchorIs() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    let clock = TestClock()
    fixture.state.remoteLaunchClock = clock
    fixture.state.remoteLaunchOriginBySurface[fixture.surfaceID] = Self.origin(
      recipe: SSHConnectionRecipe(destination: "mini"))
    probe.job = launchSSHJob
    await detect(fixture)
    await settle { fixture.source.recipes.count == 1 }
    await deliver(
      fixture, snapshot(1, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "zsh", directory: "/srv/a")))
    let refreshes = fixture.source.refreshes

    let fresh = Task { await fixture.state.remoteSplitDirectory(anchorSurfaceID: fixture.surfaceID, override: nil) }
    await settle { fixture.source.refreshes > refreshes }
    await deliver(
      fixture, snapshot(2, pane: fixture.surfaceID, foreground: remoteProcess(200, name: "zsh", directory: "/srv/b")))
    #expect(await fresh.value == "/srv/b")

    // A failed snapshot keeps the last known directory.
    await deliver(
      fixture,
      RemoteProbeSnapshot(
        connection: ConnectionKey(user: "onevcat", hostname: "mini.local"), connectionEpoch: 0, sequence: 3,
        startedAt: Self.uptime, finishedAt: Self.uptime, outcome: .failed(.unreachable), report: nil))
    #expect(fixture.state.remotePaneTrackers[fixture.surfaceID]?.foregroundWorkingDirectory == "/srv/b")
    let stale = Task { await fixture.state.remoteSplitDirectory(anchorSurfaceID: fixture.surfaceID, override: nil) }
    await settle { fixture.source.refreshes > refreshes + 1 }
    await clock.advance(by: WorktreeTerminalState.splitDirectoryTimeout)
    #expect(await stale.value == "/srv/b")
  }

  /// The kill switch still turns detection off for a remote folder's pane.
  @Test func theKillSwitchTurnsOffARemoteFolderPane() async {
    let probe = Probe()
    let fixture = makeFixture(probe: probe)
    fixture.state.remoteAgentDetectionEnabledForTesting = nil
    fixture.state.remoteDetectionEnvironmentForTesting = ["PROWL_REMOTE_AGENT_DETECTION": "0"]
    fixture.state.remoteLaunchOriginBySurface[fixture.surfaceID] = Self.origin(
      recipe: SSHConnectionRecipe(destination: "mini"))

    probe.job = launchSSHJob
    await detect(fixture)
    for _ in 0..<50 { await Task.yield() }

    #expect(fixture.state.remotePaneTrackers[fixture.surfaceID] == nil)
    #expect(fixture.source.attempts == 0)
  }

  @Test func paneShellsExportThePaneIdUnderAnSSHForwardedName() {
    let surface = GhosttySurfaceView(
      runtime: GhosttyRuntime(), workingDirectory: nil, fontSize: nil, context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true)
    #expect(surface.launchEnvironment["LC_PROWL_PANE"] == surface.id.uuidString)
    #expect(surface.launchEnvironment["PROWL_PANE_ID"] == surface.id.uuidString)
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
