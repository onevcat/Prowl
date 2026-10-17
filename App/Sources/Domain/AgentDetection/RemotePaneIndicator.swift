import Foundation

/// What a pane shows about its foreground `ssh` (docs-ai 082, L0 item 10).
nonisolated enum RemotePaneIndicator: Hashable, Sendable {
  /// How long the pane says that its `ssh` ended.
  static let endedMarkerDuration: TimeInterval = 5

  /// The pane's foreground `ssh` (this local generation) reaches this host. `issue` is the
  /// correlation that keeps Prowl from reading the pane's agents, whether or not an agent
  /// is listed (L0-8); nil while it correlates or is still pending.
  case connected(host: String, ssh: LocalProcessGeneration, issue: RemotePaneCorrelation? = nil)
  /// That `ssh` exited at this time, so the pane is back in its local shell.
  case ended(host: String, endedAt: Date)

  var connectedHost: String? {
    guard case .connected(let host, _, _) = self else { return nil }
    return host
  }

  /// The ended marker describes one exit: it shows for `endedMarkerDuration` after it,
  /// however often a view mounts.
  func showsEndedMarker(now: Date) -> Bool {
    guard case .ended(_, let endedAt) = self else { return false }
    return now.timeIntervalSince(endedAt) < Self.endedMarkerDuration
  }

  /// The correlation states a pane reports as an issue.
  static func issue(_ correlation: RemotePaneCorrelation) -> RemotePaneCorrelation? {
    switch correlation {
    case .pending, .correlated: nil
    case .ambiguous, .unmapped, .probeUnavailable, .unsupported: correlation
    }
  }
}
