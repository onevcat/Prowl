import Foundation

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
nonisolated enum RemotePaneCorrelation: Equatable, Sendable {
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
  private var retired = false
  private var lastRequestAt: TimeInterval?
  private(set) var latest: RemoteProbeSnapshot?
  private var consumedSequence: (epoch: UInt64, sequence: UInt64)?

  /// The remote session's anchor, learned from the snapshot that first carried this
  /// pane's id. On macOS the id is readable only from non-platform foreground processes, so
  /// the session that showed it once is recognized by its anchor when the system shell is
  /// back in front.
  private var anchor: Int32?
  private var bound: IdentifiedAgentProcess?
  private var presence = RemoteProcessPresence()
  private var boundFence: Date?
  /// Whether any agent was bound since this `ssh` started; the first agent's reports
  /// count from the `ssh` start, a successor's only after the snapshot that confirmed it.
  private var hadAgent = false

  init(
    surfaceID: UUID,
    ssh: LocalProcessGeneration,
    invocation: SSHInvocation,
    source: RemoteSnapshotSource,
    uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    onSnapshot: @escaping @MainActor () -> Void
  ) {
    self.surfaceID = surfaceID
    self.ssh = ssh
    self.invocation = invocation
    self.source = source
    self.uptime = uptime
    self.onSnapshot = onSnapshot
  }

  /// Opens the connection lease and consumes snapshots until the tracker retires.
  func start() {
    guard connectTask == nil, case .supported(let recipe) = invocation else { return }
    let source = source
    connectTask = Task { [weak self] in
      guard let lease = await source.connect(recipe) else {
        self?.connectFailed = true
        self?.onSnapshot()
        return
      }
      guard let self, !self.retired else {
        await lease.close()
        return
      }
      self.lease = lease
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

  /// Asks for a snapshot on the next tick, whatever the cadence (a key press or a report).
  func requestSoon() {
    lastRequestAt = nil
  }

  /// One tick's view. Requests a refresh when the cadence is due; reads only the latest
  /// snapshot, so pane ticks never wait for the host.
  func observe(active: Bool, now: Date) -> Observation {
    requestRefreshIfDue(active: active)
    var verdict: RemoteProcessPresence.Verdict?
    if let latest, let report = latest.report,
      consumedSequence.map({ $0 != (latest.connectionEpoch, latest.sequence) }) ?? true
    {
      consumedSequence = (latest.connectionEpoch, latest.sequence)
      verdict = consume(latest, report: report, now: now)
    }
    return Observation(
      correlation: correlation, connection: lease?.connection, identified: bound, verdict: verdict,
      programStatusFence: boundFence)
  }

  /// Applies a new snapshot to the binding and returns its verdict for the bound agent.
  private func consume(_ snapshot: RemoteProbeSnapshot, report: RemoteProbeReport, now: Date)
    -> RemoteProcessPresence.Verdict?
  {
    let mapped = sessions(in: report)
    if anchor == nil, mapped.count == 1, mapped[0].paneID == surfaceID { anchor = mapped[0].anchorPID }
    // Only this pane's own session is evidence about its agent: an unmapped or
    // ambiguous scan proves nothing (C3).
    guard mapped.count == 1 else { return bound == nil ? nil : .unchanged }
    let job = correlatedJob(report: report)
    if let identified = job.flatMap(identifyAgentInJob), identified.process.ref != bound?.process.ref {
      bound = identified
      presence = RemoteProcessPresence()
      boundFence = hadAgent ? now : ssh.startedAt
      hadAgent = true
    }
    guard let current = bound else { return nil }
    let contains = job?.processes.contains { $0.ref == current.process.ref } ?? false
    let verdict = presence.observe(snapshot, contains: contains, now: uptime())
    if verdict == .released {
      bound = nil
      presence = RemoteProcessPresence()
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
    switch sessions(in: report).count {
    case 0: return latest.isComplete ? .unmapped : .pending
    case 1: return .correlated
    default: return .ambiguous
    }
  }

  private func sessions(in report: RemoteProbeReport) -> [RemoteProbeSession] {
    report.sessions.filter { session in
      session.paneID == surfaceID || (session.paneID == nil && anchor != nil && session.anchorPID == anchor)
    }
  }

  private func correlatedJob(report: RemoteProbeReport) -> ForegroundJob? {
    let matching = sessions(in: report)
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
