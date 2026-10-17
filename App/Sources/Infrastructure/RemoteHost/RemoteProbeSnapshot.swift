import Foundation

/// Why a probe produced no usable report (docs-ai 082, C3). Each reason maps to a
/// different fix for the user, so the UX can name it.
nonisolated enum RemoteProbeFailure: Hashable, Sendable {
  /// The key was refused or no key was available without a prompt (`BatchMode`).
  case authentication
  /// The host key is unknown or changed.
  case hostKey
  case unresolvableHost
  case unreachable
  /// The command could not start (`ssh` missing or not executable).
  case launch(String)
  /// Any other non-zero exit; the reason is the last line `ssh` printed.
  case exit(Int32, String)
  /// The output was not the probe's format (for example a shell that prints a banner).
  case unrecognizedOutput
}

/// One probe run as subscribers see it (docs-ai 082, C3). Times are local monotonic
/// seconds (`systemUptime`), never derived from the host's clock.
nonisolated struct RemoteProbeSnapshot: Equatable, Sendable {
  enum Outcome: Equatable, Sendable {
    /// Every record arrived and the counts matched.
    case complete
    /// Some records arrived; nothing in it proves absence.
    case partial
    case failed(RemoteProbeFailure)
    case timedOut
  }

  let connection: ConnectionKey
  /// Bumped when the owner reconnects after a failure; records of different epochs are
  /// never compared.
  let connectionEpoch: UInt64
  /// Increments once per probe run of one owner.
  let sequence: UInt64
  let startedAt: TimeInterval
  let finishedAt: TimeInterval
  let outcome: Outcome
  let report: RemoteProbeReport?

  /// Only a complete snapshot proves that a process is absent.
  var isComplete: Bool { outcome == .complete }

  /// A snapshot is fresh for `freshnessWindow` after its run started; an older
  /// observation is "status unavailable", never Idle, Done or exit.
  static let freshnessWindow: TimeInterval = 10

  func isFresh(now: TimeInterval) -> Bool {
    now - startedAt <= Self.freshnessWindow
  }
}

/// The presence of one remote process across snapshots, from one consumer's view
/// (docs-ai 082, C3). A sequence counts once however often a pane ticks; only complete
/// fresh snapshots count toward absence, and two consecutive ones release the process.
/// Partial, failed, or stale snapshots neither prove absence nor reset the count.
nonisolated struct RemoteProcessPresence: Equatable, Sendable {
  enum Verdict: Equatable, Sendable {
    case present
    /// Missing from complete snapshots, but not yet from enough of them.
    case missing
    case released
    /// No new evidence: a repeated sequence, an older epoch, or an inconclusive run.
    case unchanged
  }

  static let releaseAfterMissingSnapshots = 2

  private(set) var connectionEpoch: UInt64?
  private(set) var lastSequence: UInt64?
  private(set) var consecutiveMissing = 0
  /// When a complete snapshot last confirmed the process.
  private(set) var lastSeenAt: TimeInterval?

  init() {}

  mutating func observe(_ snapshot: RemoteProbeSnapshot, contains: Bool, now: TimeInterval) -> Verdict {
    if let connectionEpoch, snapshot.connectionEpoch < connectionEpoch { return .unchanged }
    if snapshot.connectionEpoch == connectionEpoch, let lastSequence, snapshot.sequence <= lastSequence {
      return .unchanged
    }
    connectionEpoch = snapshot.connectionEpoch
    lastSequence = snapshot.sequence
    guard snapshot.report != nil, snapshot.isFresh(now: now) else { return .unchanged }
    if contains {
      consecutiveMissing = 0
      lastSeenAt = snapshot.startedAt
      return .present
    }
    guard snapshot.isComplete else { return .unchanged }
    consecutiveMissing += 1
    return consecutiveMissing >= Self.releaseAfterMissingSnapshots ? .released : .missing
  }

  /// Whether the last confirmation is too old to describe the process.
  func isStale(now: TimeInterval) -> Bool {
    guard let lastSeenAt else { return true }
    return now - lastSeenAt > RemoteProbeSnapshot.freshnessWindow
  }
}
