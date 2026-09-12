import Foundation

/// Internal detection facts, separate from public hook and workflow signals.
nonisolated enum AgentDetectionEvent: Sendable {
  case screen(AgentScreenDetection)
  case inventory(Set<String>)
  case turnStarted(session: String, turn: String)
  case turnEnded(session: String, turn: String)
  case childStarted(root: String, child: String, work: String)
  case childEnded(root: String, child: String, work: String?)
  case unavailable
  case interaction
  case tick
}

nonisolated struct AgentStateDecision: Equatable, Sendable {
  var state: AgentRawState
  var reason: String
  var logSessionID: String?
  var hasOutstandingWork = false
}

/// Pure transition policy. Time is monotonic seconds supplied by the coordinator.
nonisolated struct AgentStateMachine: Sendable {
  var activityWindow: TimeInterval = 120
  private struct Root: Sendable {
    var turn: String?
    var children: [String: String] = [:]
    var lastActivity: TimeInterval?
    var busy: Bool { turn != nil || !children.isEmpty }
  }

  private var roots: [String: Root] = [:]
  private var available = false
  private var screen = AgentScreenDetection(state: .unknown, reason: .noRuleMatched)
  private var stableScreen: AgentRawState = .unknown
  private var suppressedScreen: AgentScreenDetection?
  private(set) var decision = AgentStateDecision(state: .unknown, reason: "screen.unknown")

  @discardableResult
  mutating func receive(_ event: AgentDetectionEvent, now: TimeInterval) -> AgentStateDecision {
    switch event {
    case .screen(let detection):
      screen = detection
      if detection.state != .unknown { stableScreen = detection.state }
      if suppressedScreen != detection { suppressedScreen = nil }
    case .inventory(let sessions):
      available = true
      roots = roots.filter { sessions.contains($0.key) }
      for session in sessions where roots[session] == nil { roots[session] = Root() }
    case .turnStarted(let session, let turn):
      if roots[session] != nil, roots[session]?.turn != turn {
        roots[session]?.turn = turn
        roots[session]?.lastActivity = now
        suppressedScreen = nil
      }
    case .turnEnded(let session, let turn):
      if roots[session]?.turn == turn {
        roots[session]?.turn = nil
        roots[session]?.lastActivity = now
        suppressCompletedScreen(session: session)
      }
    case .childStarted(let root, let child, let work):
      roots[root]?.children[child] = work
    case .childEnded(let root, let child, let work):
      if let current = roots[root]?.children[child], work == current {
        roots[root]?.children.removeValue(forKey: child)
        suppressCompletedScreen(session: root)
      }
    case .unavailable:
      available = false
      roots.removeAll()
      suppressedScreen = nil
    case .interaction:
      suppressedScreen = nil
    case .tick:
      break
    }
    decision = resolve(now: now)
    return decision
  }

  private mutating func suppressCompletedScreen(session: String) {
    if decision.logSessionID == session, roots[session]?.busy == false {
      suppressedScreen = screen
    }
  }

  private func resolve(now: TimeInterval) -> AgentStateDecision {
    let eligible = roots.filter { _, root in
      root.busy || root.lastActivity.map { now - $0 < activityWindow } == true
    }
    guard available, eligible.count == 1, let (id, root) = eligible.first else {
      let reason = !available ? "screen.logUnavailable" : eligible.count > 1 ? "screen.ambiguousLogs" : "screen.noLiveTurn"
      return AgentStateDecision(state: stableScreen, reason: reason)
    }
    if screen.state == .blocked, suppressedScreen != screen {
      return AgentStateDecision(state: .blocked, reason: screen.reason.identifier, logSessionID: id,
                                hasOutstandingWork: root.busy)
    }
    if root.busy {
      return AgentStateDecision(state: .working, reason: "log.openWork", logSessionID: id, hasOutstandingWork: true)
    }
    // A turn end beats its retained frame, but cannot suppress a subsequent UI interaction.
    if suppressedScreen == nil, screen.state == .working {
      return AgentStateDecision(state: .working, reason: "screen.afterTurn", logSessionID: id)
    }
    return AgentStateDecision(state: .idle, reason: "log.turnEnded", logSessionID: id)
  }
}
