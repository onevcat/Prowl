import Foundation

/// The OSC fence of one local `ssh` generation (docs-ai 082, L0 item 5): the first agent
/// since the `ssh` started counts reports from the `ssh` start, a successor only those after
/// the snapshot that confirmed it. The terminal keeps it with the surface's record store, so
/// a tracker recreated for the same `ssh` (an undone close) never moves the fence back.
nonisolated struct RemoteFenceHistory: Equatable, Sendable {
  let ssh: LocalProcessGeneration
  /// The agent the fence belongs to.
  private(set) var process: ProcessRef?
  private(set) var fence: Date?
  /// When the `ssh`'s current foreground interval began; nil for the first one, which
  /// counts from the `ssh` start.
  private(set) var foregroundSince: Date?
  /// The `ssh` left the foreground (a local agent took over); the next tracker starts a new
  /// interval. A closed and restored pane keeps its interval.
  var leftForeground = false
  /// The accepted degraded binding (L0 item 9), restored with the pane.
  var unprobedAgent: DetectedAgent?

  init(ssh: LocalProcessGeneration) {
    self.ssh = ssh
  }

  /// The history a new tracker continues with: a new foreground interval, without the
  /// degraded binding, when the `ssh` left the foreground in between.
  func resumed(at now: Date) -> RemoteFenceHistory {
    guard leftForeground else { return self }
    var next = self
    next.foregroundSince = now
    next.leftForeground = false
    next.unprobedAgent = nil
    return next
  }

  mutating func bind(_ process: ProcessRef, confirmedAt now: Date) {
    guard process != self.process else { return }
    fence = self.process == nil && fence == nil ? ssh.startedAt : now
    self.process = process
  }
}

/// A pane's subscription to the host its foreground `ssh` reaches (docs-ai 082, L0).
nonisolated struct RemoteConnectionLease: Sendable {
  let connection: ConnectionKey
  let snapshots: AsyncStream<RemoteProbeSnapshot>
  let refresh: @Sendable () async -> Void
  let close: @Sendable () async -> Void
}

/// Opens leases; the live source resolves the recipe with `ssh -G` and leases the host's
/// connection owner from the shared registry.
nonisolated struct RemoteSnapshotSource: Sendable {
  var connect: @Sendable (SSHConnectionRecipe) async -> RemoteConnectionLease?

  static let live = RemoteSnapshotSource { recipe in
    let registry = RemoteConnectionRegistry.shared
    guard let key = await registry.resolve(recipe) else { return nil }
    let owner = await registry.acquire(key, recipe: recipe)
    let (id, snapshots) = await owner.subscribe()
    return RemoteConnectionLease(
      connection: key,
      snapshots: snapshots,
      refresh: { await owner.requestRefresh() },
      close: {
        await owner.unsubscribe(id)
        await registry.release(key)
      })
  }
}

/// How a pane relates to the remote host's sessions (docs-ai 082, L0 item 1). Prowl never
/// picks an arbitrary session: anything but `correlated` leaves the pane without a probed
/// remote agent.
nonisolated enum RemotePaneCorrelation: Hashable, Sendable {
  /// The connection is being resolved or the first snapshot has not arrived.
  case pending
  /// Exactly one session on the host carries this pane's id.
  case correlated
  /// More than one session carries this pane's id (for example two `ssh` jobs).
  case ambiguous
  /// A complete snapshot has no session with this pane's id (`AcceptEnv` or `SendEnv`
  /// missing, `-F` without `SendEnv`, or a shell whose environment the host hides).
  case unmapped
  /// No usable snapshot: the connection failed, timed out, or was refused.
  case probeUnavailable(RemoteProbeFailure?)
  /// The local `ssh` command line is outside the supported grammar.
  case unsupported(String)
  /// The pane's session shows a tmux client whose server the probe cannot reach, for
  /// example one started with `tmux -S` outside the default socket directory.
  case tmuxUnreachable
}

/// Tracks one pane's foreground `ssh` and the remote agent it shows (docs-ai 082, L0).
///
/// It belongs to one local `ssh` generation; a new `ssh` gets a new tracker, and the old
/// one's late snapshots are dropped with it. The pane's detection loop asks it for an
/// observation on every tick; snapshots arrive from the host's connection owner and wake
/// the loop.
@MainActor
final class RemotePaneTracker {
  struct Observation: Equatable {
    var correlation: RemotePaneCorrelation
    var connection: ConnectionKey?
    /// The bound remote agent: identified from a snapshot and held until the snapshot rule
    /// releases it, so every tick sees the same generation.
    var identified: IdentifiedAgentProcess?
    /// What the latest new snapshot says about the bound remote agent; nil when no agent
    /// is bound or no new snapshot arrived.
    var verdict: RemoteProcessPresence.Verdict?
    /// The arrival-time fence for OSC records of the bound remote agent (L0 item 5).
    var programStatusFence: Date?
    /// When a snapshot last confirmed the bound agent, or for an unprobed binding, when its
    /// producer last reported.
    var confirmedAt: Date?

    func context(now: Date, stateKnown: Bool = true) -> RemoteAgentContext {
      RemoteAgentContext(
        connection: connection, correlation: correlation, confirmedAt: confirmedAt, now: now, stateKnown: stateKnown,
        isUnprobed: identified.map { if case .unprobedRemote = $0.process.ref { true } else { false } } ?? false)
    }
  }

  var boundAgent: IdentifiedAgentProcess? { bound }

  /// Probe cadence while a remote agent is bound or the pane settles after a wake.
  static let activeCadence: TimeInterval = 1
  /// Probe cadence while the pane shows a remote shell.
  static let idleCadence: TimeInterval = 3
  /// The least spacing of probes a changing local screen asks for: under sustained output
  /// one probe runs at a time (the owner coalesces the rest) and the capture keeps up.
  static let screenChangeSpacing: TimeInterval = 0.25

  let surfaceID: UUID
  /// The local `ssh` process this tracker belongs to.
  let ssh: LocalProcessGeneration
  let invocation: SSHInvocation
  private let source: RemoteSnapshotSource
  private let onSnapshot: @MainActor () -> Void
  private let uptime: () -> TimeInterval

  private var lease: RemoteConnectionLease?
  private var connectTask: Task<Void, Never>?
  private var connectFailed = false
  private var connectFailures = 0
  /// When a failed connection may be tried again (bounded exponential backoff).
  private var nextConnectAt: TimeInterval?
  private var retired = false
  private var lastRequestAt: TimeInterval?
  private(set) var latest: RemoteProbeSnapshot?
  /// The pane's session shows a tmux client (docs-ai 082, S5); a gap keeps it.
  private(set) var isInTmux = false
  /// The latest capture whose pane runs the bound agent, and when (`uptime`) it was acquired.
  private var tmuxCapture: (screen: String, acquiredAt: TimeInterval)?
  /// The bound agent was last seen in a tmux pane: its screen stays its pane's capture
  /// until it is seen elsewhere or released, even after the client detaches back to the
  /// remote shell.
  private var boundFromTmux = false
  private var consumedSequence: (epoch: UInt64, sequence: UInt64)?
  /// Callers of `refreshedWorkingDirectory` that wait for a snapshot started after their
  /// request (`uptime`), each with its own timeout.
  private var snapshotWaiters: [UUID: (requestedAt: TimeInterval, continuation: CheckedContinuation<Void, Never>)] =
    [:]
  /// The last directory a snapshot showed, kept through a failed or unmapped one.
  private var lastKnownWorkingDirectory: String?

  /// The remote session's anchor, learned from a snapshot that carried this pane's id. On
  /// macOS the id is readable only from non-platform foreground processes, so the session
  /// that showed it is recognized by its anchor when the system shell is back in front. The
  /// anchor is valid only within the connection epoch and boot it was seen in: a pid in a
  /// new scope can be another session.
  private var anchor: Anchor?

  private struct Anchor {
    let pid: Int32
    let epoch: UInt64
    let bootID: String
  }
  private var bound: IdentifiedAgentProcess?
  /// An agent known only from its OSC records (L0 item 9); released only with the `ssh`.
  private var unprobed: IdentifiedAgentProcess?
  private var confirmedAt: Date?
  private var presence = RemoteProcessPresence()
  /// The OSC fence of this `ssh` generation; it outlives the tracker (close and Undo).
  private(set) var fenceHistory: RemoteFenceHistory

  init(
    surfaceID: UUID,
    ssh: LocalProcessGeneration,
    invocation: SSHInvocation,
    fenceHistory: RemoteFenceHistory? = nil,
    source: RemoteSnapshotSource,
    now: Date = Date(),
    uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    onSnapshot: @escaping @MainActor () -> Void
  ) {
    self.surfaceID = surfaceID
    self.ssh = ssh
    self.invocation = invocation
    let retained = fenceHistory.flatMap { $0.ssh == ssh ? $0 : nil }
    self.fenceHistory = retained?.resumed(at: now) ?? RemoteFenceHistory(ssh: ssh)
    self.source = source
    self.uptime = uptime
    self.onSnapshot = onSnapshot
  }

  /// Longest wait between connection attempts after failures.
  static let maximumConnectBackoff: TimeInterval = 30

  /// Opens the connection lease and consumes snapshots until the tracker retires. A failed
  /// attempt (for example `ssh -G` during a DNS change) is retried with a growing delay,
  /// or at once on the next wake.
  func start() {
    guard connectTask == nil, lease == nil, !retired, case .supported(let recipe) = invocation else { return }
    nextConnectAt = nil
    let source = source
    connectTask = Task { [weak self] in
      guard let lease = await source.connect(recipe) else {
        guard let self else { return }
        self.connectFailed = true
        self.connectFailures += 1
        self.nextConnectAt =
          self.uptime() + min(Self.maximumConnectBackoff, pow(2, Double(self.connectFailures - 1)))
        self.connectTask = nil
        self.onSnapshot()
        return
      }
      guard let self, !self.retired else {
        await lease.close()
        return
      }
      self.lease = lease
      self.connectFailed = false
      self.connectFailures = 0
      self.lastRequestAt = self.uptime()
      await lease.refresh()
      for await snapshot in lease.snapshots {
        guard !self.retired, !Task.isCancelled else { break }
        self.latest = snapshot
        if let directory = self.currentForegroundWorkingDirectory { self.lastKnownWorkingDirectory = directory }
        self.resumeSnapshotWaiters(startedAt: snapshot.startedAt)
        self.onSnapshot()
      }
    }
  }

  /// Ends the subscription; snapshots that arrive later are dropped.
  func retire() {
    guard !retired else { return }
    retired = true
    resumeSnapshotWaiters(startedAt: .infinity)
    connectTask?.cancel()
    if let lease {
      Task { await lease.close() }
    }
  }

  /// Asks for a snapshot on the next tick, whatever the cadence (a key press or a report);
  /// a failed connection is tried again on that tick.
  func requestSoon() {
    lastRequestAt = nil
    if nextConnectAt != nil { nextConnectAt = uptime() }
  }

  /// One tick's view. Requests a refresh when the cadence is due; reads only the latest
  /// snapshot, so pane ticks never wait for the host.
  func observe(active: Bool, now: Date) -> Observation {
    if let nextConnectAt, uptime() >= nextConnectAt { start() }
    requestRefreshIfDue(active: active)
    var verdict: RemoteProcessPresence.Verdict?
    if let latest, let report = latest.report,
      consumedSequence.map({ $0 != (latest.connectionEpoch, latest.sequence) }) ?? true
    {
      consumedSequence = (latest.connectionEpoch, latest.sequence)
      verdict = consume(latest, report: report, now: now)
    }
    // A probed session supersedes the unprobed binding: its own evidence decides from here.
    if correlation == .correlated {
      unprobed = nil
      fenceHistory.unprobedAgent = nil
    }
    // A restored pane resumes the binding it had accepted.
    if unprobed == nil, bound == nil, let agent = fenceHistory.unprobedAgent, correlation != .correlated {
      unprobed = makeUnprobed(agent)
    }
    if bound == nil, let unprobed {
      return Observation(
        correlation: correlation, connection: lease?.connection, identified: unprobed, verdict: nil,
        programStatusFence: ssh.startedAt, confirmedAt: nil)
    }
    return Observation(
      correlation: correlation, connection: lease?.connection, identified: bound, verdict: verdict,
      programStatusFence: boundRecordFence, confirmedAt: confirmedAt)
  }

  /// The working directory of the foreground process of the pane's session (inside tmux, of
  /// the client's active pane): from the latest snapshot, else the last one that showed it.
  /// nil when no snapshot mapped the session or the host did not read it (docs-ai 084 C4).
  var foregroundWorkingDirectory: String? {
    currentForegroundWorkingDirectory ?? lastKnownWorkingDirectory
  }

  /// The latest snapshot's directory. A tmux client whose server Prowl cannot read hides
  /// where the user works, so it has none.
  private var currentForegroundWorkingDirectory: String? {
    guard let session = mappedSession(), !session.hasUnreadTmuxPane else { return nil }
    let processes = session.tmux?.processes ?? session.processes
    let group = session.tmux?.foregroundProcessGroupID ?? session.foregroundProcessGroupID
    let members = processes.filter { $0.processGroupID == group }
    return (members.first { $0.pid == group } ?? members.first)?.workingDirectory
  }

  /// The working directory of the bound remote agent in the latest snapshot, else the
  /// session's foreground one.
  var agentWorkingDirectory: String? {
    if let session = mappedSession(), case .remote(let ref) = bound?.process.ref {
      let processes = (session.tmux?.processes ?? []) + session.processes
      if let process = processes.first(where: { $0.pid == ref.pid && $0.startToken == ref.startToken }),
        let directory = process.workingDirectory
      {
        return directory
      }
    }
    return foregroundWorkingDirectory
  }

  /// The foreground working directory after a fresh snapshot, or the last known one when
  /// none arrives within `timeout` (a split opens where the pane is, docs-ai 084 C4).
  func refreshedWorkingDirectory(timeout: Duration, clock: any Clock<Duration>) async -> String? {
    guard let lease, !retired else { return foregroundWorkingDirectory }
    let id = UUID()
    let requestedAt = uptime()
    await withCheckedContinuation { continuation in
      snapshotWaiters[id] = (requestedAt, continuation)
      Task { await lease.refresh() }
      Task { [weak self] in
        try? await clock.sleep(for: timeout)
        self?.snapshotWaiters.removeValue(forKey: id)?.continuation.resume()
      }
    }
    return foregroundWorkingDirectory
  }

  /// Resumes the waiters whose request came before `startedAt`: a snapshot that started
  /// earlier (a cadence probe already running) may predate the user's last `cd`.
  private func resumeSnapshotWaiters(startedAt: TimeInterval) {
    for (id, waiter) in snapshotWaiters where waiter.requestedAt <= startedAt {
      snapshotWaiters.removeValue(forKey: id)
      waiter.continuation.resume()
    }
  }

  /// The pane's own session in the latest snapshot.
  private func mappedSession() -> RemoteProbeSession? {
    guard let latest, let report = latest.report else { return nil }
    let matching = sessions(in: report, epoch: latest.connectionEpoch)
    return matching.count == 1 ? matching[0] : nil
  }

  /// The agent's screen when the pane's session shows a tmux client (L0 item 6).
  enum TmuxScreen: Equatable {
    /// The latest capture of the bound agent's own pane.
    case capture(String)
    /// No capture of that pane is fresh: the state is unknown, and the local screen (the
    /// client's view) never stands in for it.
    case unavailable
  }

  /// nil outside tmux, where the local screen is the agent's screen. Inside, the last
  /// capture that showed the bound agent's pane counts for `RemoteAgentContext.staleAfter`
  /// after its acquisition; a failed or partial probe, or a capture of another pane (a
  /// switch the presence rule has not released yet), does not replace it.
  func tmuxScreen() -> TmuxScreen? {
    guard isInTmux || (bound != nil && boundFromTmux) else { return nil }
    guard let tmuxCapture, uptime() - tmuxCapture.acquiredAt <= RemoteAgentContext.staleAfter else {
      return .unavailable
    }
    return .capture(tmuxCapture.screen)
  }

  /// The local screen of a tmux pane changed: the tmux client drew something, so the
  /// capture is likely out of date. Asks for a probe now, at most every
  /// `screenChangeSpacing`.
  func requestRefreshForScreenChange() {
    guard let lease, !retired else { return }
    let now = uptime()
    if let lastRequestAt, now - lastRequestAt < Self.screenChangeSpacing { return }
    lastRequestAt = now
    Task { await lease.refresh() }
  }

  /// The arrival fence of a probed agent: its successor fence, raised to the start of the
  /// `ssh`'s current foreground interval, so a local agent run while the `ssh` was
  /// suspended never decides for the resumed remote one.
  var boundRecordFence: Date? {
    [fenceHistory.fence, fenceHistory.foregroundSince].compactMap(\.self).max()
  }

  /// Whether a verified producer's report may stand in for a probed agent: the host cannot
  /// be probed, the pane is not mapped, or its `ssh` command line is outside the grammar.
  var allowsUnprobedBinding: Bool {
    guard bound == nil else { return false }
    switch correlation {
    case .unmapped, .probeUnavailable, .unsupported: return true
    // tmux drops OSC 7501, and the local screen is the client's view.
    case .pending, .correlated, .ambiguous, .tmuxUnreachable: return false
    }
  }

  /// The earliest arrival a degraded binding counts: the `ssh` start, raised to this
  /// foreground interval's start when the `ssh` was resumed, and to the retained successor
  /// fence, so a record that an earlier binding of this `ssh` excluded never comes back.
  var unprobedRecordFence: Date {
    [ssh.startedAt, fenceHistory.foregroundSince, fenceHistory.fence].compactMap(\.self).max() ?? ssh.startedAt
  }

  /// Binds `agent` from its OSC root record (L0 item 9). The reference names this `ssh`,
  /// never a remote pid.
  func bindUnprobed(_ agent: DetectedAgent) -> IdentifiedAgentProcess {
    if let unprobed, unprobed.agent == agent { return unprobed }
    let identified = makeUnprobed(agent)
    unprobed = identified
    fenceHistory.unprobedAgent = agent
    return identified
  }

  private func makeUnprobed(_ agent: DetectedAgent) -> IdentifiedAgentProcess {
    IdentifiedAgentProcess(
      agent: agent, name: agent.iconLookupToken,
      process: ForegroundProcess(
        ref: .unprobedRemote(ssh), parentPID: nil, name: agent.iconLookupToken, argv0: nil, cmdline: nil))
  }

  /// Applies a new snapshot to the binding and returns its verdict for the bound agent.
  private func consume(_ snapshot: RemoteProbeSnapshot, report: RemoteProbeReport, now: Date)
    -> RemoteProcessPresence.Verdict?
  {
    let mapped = sessions(in: report, epoch: snapshot.connectionEpoch)
    if mapped.count == 1, mapped[0].paneID == surfaceID {
      anchor = Anchor(pid: mapped[0].anchorPID, epoch: snapshot.connectionEpoch, bootID: report.bootID)
    }
    // Only this pane's own session is evidence about its agent: an unmapped or
    // ambiguous scan proves nothing (C3).
    guard mapped.count == 1 else { return bound == nil ? nil : .unchanged }
    // The session shows a tmux client whose server the probe could not reach: its own
    // foreground is that client, so the snapshot says nothing about the agent in the pane.
    if mapped[0].hasUnreadTmuxPane {
      isInTmux = true
      return bound == nil ? nil : .unchanged
    }
    // A partial snapshot that lost the tmux records is a gap, not a client that left.
    if snapshot.isComplete || mapped[0].tmux != nil { isInTmux = mapped[0].tmux != nil }
    let job = correlatedJob(report: report, epoch: snapshot.connectionEpoch)
    if let identified = job.flatMap(identifyAgentInJob), identified.process.ref != bound?.process.ref {
      bound = identified
      tmuxCapture = nil
      presence = RemoteProcessPresence()
      fenceHistory.bind(identified.process.ref, confirmedAt: now)
    }
    guard let current = bound else { return nil }
    let contains = job?.processes.contains { $0.ref == current.process.ref } ?? false
    // Freshness counts from the snapshot's acquisition, not from when a tick read it.
    let acquiredAt = now.addingTimeInterval(-max(0, uptime() - snapshot.startedAt))
    // A capture describes the bound agent only when its pane runs that agent; where the
    // agent was last seen decides which screen is its own.
    if contains {
      boundFromTmux = mapped[0].tmux != nil
      if let screen = mapped[0].tmux?.screen { tmuxCapture = (screen, snapshot.startedAt) }
    }
    let verdict = presence.observe(snapshot, contains: contains, now: uptime())
    switch verdict {
    case .present:
      confirmedAt = acquiredAt
    case .released:
      bound = nil
      confirmedAt = nil
      tmuxCapture = nil
      boundFromTmux = false
      presence = RemoteProcessPresence()
    case .missing, .unchanged:
      break
    }
    return verdict
  }

  var correlation: RemotePaneCorrelation {
    if case .unsupported(let reason) = invocation { return .unsupported(reason) }
    if connectFailed { return .probeUnavailable(nil) }
    guard let latest else { return .pending }
    guard let report = latest.report else {
      if case .failed(let failure) = latest.outcome { return .probeUnavailable(failure) }
      return .probeUnavailable(nil)
    }
    let mapped = sessions(in: report, epoch: latest.connectionEpoch)
    switch mapped.count {
    case 0: return latest.isComplete ? .unmapped : .pending
    case 1: return mapped[0].hasUnreadTmuxPane ? .tmuxUnreachable : .correlated
    default: return .ambiguous
    }
  }

  private func sessions(in report: RemoteProbeReport, epoch: UInt64) -> [RemoteProbeSession] {
    let anchorPID = anchor.flatMap { $0.epoch == epoch && $0.bootID == report.bootID ? $0.pid : nil }
    return report.sessions.filter { session in
      session.paneID == surfaceID || (session.paneID == nil && anchorPID != nil && session.anchorPID == anchorPID)
    }
  }

  private func correlatedJob(report: RemoteProbeReport, epoch: UInt64) -> ForegroundJob? {
    let matching = sessions(in: report, epoch: epoch)
    guard matching.count == 1, let session = matching.first, let connection = lease?.connection else { return nil }
    // Inside tmux the session's own foreground is the tmux client; the agent is in the
    // client's active pane (L0 item 6).
    if let tmux = session.tmux { return tmux.foregroundJob(connection: connection, bootID: report.bootID) }
    return session.foregroundJob(connection: connection, bootID: report.bootID)
  }

  /// The cadence counts from the host's latest snapshot, which every pane on the host
  /// shares, and from this pane's last request: panes that tick out of phase do not double
  /// the probe rate.
  private func requestRefreshIfDue(active: Bool) {
    guard let lease, !retired else { return }
    let now = uptime()
    let cadence = active ? Self.activeCadence : Self.idleCadence
    if let lastRequestAt, now - lastRequestAt < cadence { return }
    if lastRequestAt != nil, let latest, now - latest.startedAt < cadence { return }
    lastRequestAt = now
    Task { await lease.refresh() }
  }
}
