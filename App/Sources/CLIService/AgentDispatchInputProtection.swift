import Foundation

nonisolated enum AgentDispatchInputProtection {
  static let recentEditingWindow: TimeInterval = 2

  static func refusal(hasMarkedText: Bool, lastEditingAt: TimeInterval?, now: TimeInterval) -> String? {
    if hasMarkedText { return "Host is composing text with an input method. Finish editing before dispatching." }
    guard now.isFinite, lastEditingAt?.isFinite != false else { return "Host input activity is unavailable." }
    if let lastEditingAt, now - lastEditingAt < recentEditingWindow {
      return "Host was just edited locally. Wait before dispatching."
    }
    return nil
  }
}
