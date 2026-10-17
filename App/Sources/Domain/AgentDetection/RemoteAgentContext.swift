import Foundation

/// What a pane's remote agent observation rests on (docs-ai 082, L0 items 9 and 10): the
/// host, the pane's correlation, and whether the host still confirms the agent.
nonisolated struct RemoteAgentContext: Equatable, Sendable {
  /// No confirming snapshot for this long makes the observation stale (C3).
  static let staleAfter: TimeInterval = 10

  var connection: ConnectionKey?
  var correlation: RemotePaneCorrelation
  /// The last snapshot that confirmed the agent; set only while the observation is stale,
  /// so a steady stream of confirmations does not change the published entry.
  var lastConfirmedAt: Date?
  var isStale: Bool
  /// False while no evidence decides the agent's state (an unrecognized screen without an
  /// eligible OSC record). The entry stays listed, but its state is evidence for nothing.
  var isStateKnown: Bool
  /// The agent is known only from its OSC records (L0 item 9): heuristic, no remote
  /// process, stale whenever its producer has been quiet for `staleAfter`.
  var isUnprobed: Bool

  /// `user@hostname`, the label a remote pane shows.
  var hostLabel: String? {
    connection?.label
  }

  init(
    connection: ConnectionKey?, correlation: RemotePaneCorrelation, confirmedAt: Date?, now: Date,
    stateKnown: Bool = true, isUnprobed: Bool = false
  ) {
    self.connection = connection
    self.correlation = correlation
    isStateKnown = stateKnown
    self.isUnprobed = isUnprobed
    let isStale = confirmedAt.map { now.timeIntervalSince($0) > Self.staleAfter } ?? true
    self.isStale = isStale
    lastConfirmedAt = isStale ? confirmedAt : nil
  }
}
