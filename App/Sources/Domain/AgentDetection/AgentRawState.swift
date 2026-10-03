import Foundation

nonisolated enum AgentRawState: String, Equatable, Sendable {
  case working
  case blocked
  case idle
  case unknown
}

nonisolated enum AgentDisplayState: String, Equatable, Sendable {
  case working
  case blocked
  case done
  case idle
}
