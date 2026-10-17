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
  private var consumedSequence: (epoch: UInt64, sequence: UInt64)?

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
        self.onSnapshot()
      }
    }
  }

  /// Ends the subscription; snapshots that arrive later are dropped.
  func retire() {
    guard !retired else { return }
    retired = true
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
    case .pending, .correlated, .ambiguous: return false
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
    let job = correlatedJob(report: report, epoch: snapshot.connectionEpoch)
    if let identified = job.flatMap(identifyAgentInJob), identified.process.ref != bound?.process.ref {
      bound = identified
      presence = RemoteProcessPresence()
      fenceHistory.bind(identified.process.ref, confirmedAt: now)
    }
    guard let current = bound else { return nil }
    let contains = job?.processes.contains { $0.ref == current.process.ref } ?? false
    let verdict = presence.observe(snapshot, contains: contains, now: uptime())
    switch verdict {
    case .present:
      // Freshness counts from the snapshot's acquisition, not from when a tick read it.
      confirmedAt = now.addingTimeInterval(-max(0, uptime() - snapshot.startedAt))
    case .released:
      bound = nil
      confirmedAt = nil
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
    switch sessions(in: report, epoch: latest.connectionEpoch).count {
    case 0: return latest.isComplete ? .unmapped : .pending
    case 1: return .correlated
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
