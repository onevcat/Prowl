import Foundation

/// Turns the pane's agent state (OSC 7501, hooks, screen rules, docs-ai 079) into
/// `agent.status` events, one per change.
nonisolated struct MirrorConversationStatusMapper: Sendable {
  private var last: MirrorConversationEvent.Status?

  mutating func event(for pane: PaneAgentState, at date: Date) -> MirrorConversationEvent? {
    guard pane.detectedAgent != nil else { return nil }
    let status = Self.status(for: pane)
    guard status != last else { return nil }
    last = status
    return MirrorConversationEvent(
      .agentStatus, .status(status), at: date, source: Self.source(of: pane.decision?.reason))
  }

  mutating func reset() {
    last = nil
  }

  static func status(for pane: PaneAgentState) -> MirrorConversationEvent.Status {
    let state = MirrorConversationEvent.AgentState(rawValue: pane.state.rawValue) ?? .unknown
    var kind: String?
    if state == .blocked {
      kind = "unspecified"
      if case .programStatus(let reason) = pane.decision?.reason {
        switch reason {
        case .blocked(let blockedKind), .childBlocked(let blockedKind): kind = blockedKind?.rawValue ?? "unspecified"
        default: break
        }
      }
    }
    return .init(state: state, kind: kind, reason: pane.decision?.reason.identifier)
  }

  static func source(of reason: AgentStateDecisionReason?) -> MirrorConversationEvent.Source {
    switch reason {
    case .programStatus: .osc
    case .screen, .fallback: .screen
    case .native: .hook
    case .logOpenWork, .logTurnEnded, nil: .host
    }
  }
}
