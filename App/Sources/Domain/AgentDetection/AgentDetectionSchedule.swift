import Foundation

enum AgentDetectionSchedule: Equatable, Sendable {
  static let warmWindow: TimeInterval = 30

  case cold
  case warm(until: Date)
  case active
  /// A verified OSC 7501 producer's root record decides the state (docs-ai 079): the
  /// tick keeps only the process probe and the session resolution, every 2 s.
  case delegated

  func warmed(now: Date) -> Self {
    switch self {
    case .active, .delegated:
      // A key press leaves delegation for one full tick so the screen is read again.
      return .active
    case .cold, .warm:
      return .warm(until: now.addingTimeInterval(Self.warmWindow))
    }
  }

  func observedAgent(now _: Date) -> Self {
    .active
  }

  func observedDelegatedAgent(now _: Date) -> Self {
    .delegated
  }

  func observedNoAgent(now: Date) -> Self {
    switch self {
    case .active, .delegated:
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
    case .delegated:
      return idleAgentDetectionInterval
    }
  }
}
