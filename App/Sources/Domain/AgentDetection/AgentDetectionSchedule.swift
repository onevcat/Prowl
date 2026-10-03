import Foundation

enum AgentDetectionSchedule: Equatable, Sendable {
  static let warmWindow: TimeInterval = 30

  case cold
  case warm(until: Date)
  case active

  func warmed(now: Date) -> Self {
    switch self {
    case .active:
      return .active
    case .cold, .warm:
      return .warm(until: now.addingTimeInterval(Self.warmWindow))
    }
  }

  func observedAgent(now _: Date) -> Self {
    .active
  }

  func observedNoAgent(now: Date) -> Self {
    switch self {
    case .active:
      return .warm(until: now.addingTimeInterval(Self.warmWindow))
    case .warm(let until) where until > now:
      return .warm(until: until)
    case .cold, .warm:
      return .cold
    }
  }

  func nextInterval(now: Date) -> Duration? {
    switch self {
    case .cold:
      return nil
    case .warm(let until):
      return until > now ? idleAgentDetectionInterval : nil
    case .active:
      return activeAgentDetectionInterval
    }
  }
}
