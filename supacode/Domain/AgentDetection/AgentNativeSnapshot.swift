import Foundation

/// Current process-scoped state, not a trusted completion receipt or a log turn edge.
nonisolated struct AgentNativeSnapshot: Equatable, Sendable {
  let sessionID: String
  let state: AgentRawState
  let statusUpdatedAt: TimeInterval
}
