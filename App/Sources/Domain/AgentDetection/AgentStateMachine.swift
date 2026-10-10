import Foundation

/// Internal detection facts, separate from public hook and workflow signals.
nonisolated enum AgentDetectionEvent: Sendable {
  case screen(AgentScreenDetection, contentID: Int? = nil)
  case native(AgentNativeSnapshot)
  case inventory(Set<String>)
  case turnStarted(session: String, turn: String)
  case turnEnded(session: String, turn: String)
  case childStarted(root: String, child: String, work: String)
  case childScheduled(root: String, child: String, work: String)
  case childEnded(root: String, child: String, work: String?)
  case unavailable
  case suspended
  case interaction
  case tick
  /// OSC 7501 evidence derived against the bound process generation (docs-ai 079);
  /// `nil` withdraws it. `revision` is the record store revision the evidence was
  /// taken at: an older or equal one is a stale poll snapshot and is ignored, so a
  /// capture that suspended before applying cannot roll back a newer push.
  case programStatus(ProgramStatusEvidence?, revision: UInt64)
}

nonisolated enum AgentScreenFallback: String, Sendable {
  case logUnavailable = "screen.logUnavailable"
  case ambiguousLogs = "screen.ambiguousLogs"
  case noLiveTurn = "screen.noLiveTurn"
  case retainedCompletion = "screen.retainedCompletion"
  case afterTurn = "screen.afterTurn"
}

nonisolated enum AgentStateDecisionReason: Equatable, Sendable {
  case screen(AgentScreenDetectionReason)
  case fallback(AgentScreenFallback)
  case native(AgentRawState)
  case logOpenWork
  case logTurnEnded
  case programStatus(ProgramStatusReason)

  var identifier: String {
    switch self {
    case .screen(let reason): reason.identifier
    case .fallback(let reason): reason.rawValue
    case .native(let state): "native.\(state.rawValue)"
    case .logOpenWork: "log.openWork"
    case .logTurnEnded: "log.turnEnded"
    case .programStatus(let reason): reason.identifier
    }
  }

  /// Whether an eligible OSC 7501 root record decided the state.
  var isProgramStatus: Bool {
    if case .programStatus = self { return true }
    return false
  }
}

nonisolated struct AgentStateDecision: Equatable, Sendable {
  var state: AgentRawState
  var reason: AgentStateDecisionReason
  var screenReason: AgentScreenDetectionReason?
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
  private var native: AgentNativeSnapshot?
  private var nativeAvailable = false
  private var available = false
  private var hasLogProvider = false
  private var screen = AgentScreenDetection(state: .unknown, reason: .noRuleMatched)
  private var stableScreen: AgentRawState = .unknown
  private var suppressedScreen: AgentScreenDetection?
  private var screenContentID: Int?
  private var suppressedContentID: Int?
  private var suppressedSessionID: String?
  private var programStatus: ProgramStatusEvidence?
  private var programStatusRevision: UInt64 = 0
  private(set) var decision = AgentStateDecision(state: .unknown, reason: .screen(.noRuleMatched))

  /// An eligible OSC 7501 root record currently decides the state.
  var hasProgramStatusAuthority: Bool { programStatus != nil }

  @discardableResult
  mutating func receive(_ event: AgentDetectionEvent, now: TimeInterval) -> AgentStateDecision {
    switch event {
    case .screen(let detection, let contentID):
      observeScreen(detection, contentID: contentID)
    case .native(let snapshot):
      observeNative(snapshot)
    case .inventory(let sessions):
      observeInventory(sessions)
    case .turnStarted(let session, let turn):
      startTurn(session: session, turn: turn, now: now)
    case .turnEnded(let session, let turn):
      endTurn(session: session, turn: turn, now: now)
    case .childScheduled(let root, let child, let work):
      scheduleChild(root: root, child: child, work: work)
    case .childStarted(let root, let child, let work):
      roots[root]?.children[child] = work
    case .childEnded(let root, let child, let work):
      endChild(root: root, child: child, work: work)
    case .suspended:
      nativeAvailable = false
      hasLogProvider = true
      available = false
    case .unavailable:
      native = nil
      nativeAvailable = false
      hasLogProvider = true
      available = false
      roots.removeAll()
      suppressedScreen = nil
    case .interaction:
      suppressedScreen = nil
    case .tick:
      break
    case .programStatus(let evidence, let revision):
      observeProgramStatus(evidence, revision: revision)
    }
    decision = resolve(now: now)
    // The screen is not read while a root record holds authority; the marker says so
    // instead of repeating a frame that may be stale.
    decision.screenReason = programStatus == nil ? screen.reason : .delegated
    return decision
  }

  /// Taking authority retires the facts the machine will not refresh while the
  /// schedule is delegated: the native snapshot, the completed-frame fence, and the
  /// log roots' recency. This is deliberately not `.suspended`: suspension keeps the
  /// snapshot and fence so a transient read failure recovers without flicker, and it
  /// sets `hasLogProvider`, which would rename a screen-only agent's fallback reason.
  /// Open log work stays accounted; a withdrawal falls back with today's reasons.
  private mutating func observeProgramStatus(_ evidence: ProgramStatusEvidence?, revision: UInt64) {
    guard revision > programStatusRevision else { return }
    programStatusRevision = revision
    if evidence != nil, programStatus == nil {
      native = nil
      nativeAvailable = false
      suppressedScreen = nil
      suppressedContentID = nil
      suppressedSessionID = nil
      for session in roots.keys { roots[session]?.lastActivity = nil }
    }
    programStatus = evidence
  }

  private mutating func observeInventory(_ sessions: Set<String>) {
    hasLogProvider = true
    available = true
    roots = roots.filter { sessions.contains($0.key) }
    for session in sessions where roots[session] == nil { roots[session] = Root() }
  }

  private mutating func startTurn(session: String, turn: String, now: TimeInterval) {
    guard roots[session] != nil, roots[session]?.turn != turn else { return }
    roots[session]?.turn = turn
    roots[session]?.lastActivity = now
    suppressedScreen = nil
  }

  private mutating func endTurn(session: String, turn: String, now: TimeInterval) {
    guard roots[session]?.turn == turn else { return }
    roots[session]?.turn = nil
    roots[session]?.lastActivity = now
    suppressCompletedScreen(session: session)
  }

  private mutating func observeNative(_ snapshot: AgentNativeSnapshot) {
    if let native, native.sessionID == snapshot.sessionID, snapshot.statusUpdatedAt < native.statusUpdatedAt {
      return
    }
    let changed = native != snapshot
    // Busy can acknowledge a retained prompt, but cannot dismiss a newly changed blocker.
    let canFence =
      screen.state != .blocked || snapshot.state == .blocked
      || (snapshot.state == .idle && native != nil) || suppressedScreen == screen
    native = snapshot
    nativeAvailable = true
    hasLogProvider = true
    if changed, canFence {
      suppressedSessionID = snapshot.sessionID
      suppressedScreen = screen
      suppressedContentID = screenContentID
    }
  }

  private mutating func observeScreen(_ detection: AgentScreenDetection, contentID: Int?) {
    screen = detection
    screenContentID = contentID
    if detection.state != .unknown { stableScreen = detection.state }
    if suppressedScreen != detection || suppressedContentID != contentID { suppressedScreen = nil }
  }

  private mutating func endChild(root: String, child: String, work: String?) {
    if let current = roots[root]?.children[child], work == current {
      roots[root]?.children.removeValue(forKey: child)
      suppressCompletedScreen(session: root)
    }
  }

  private mutating func scheduleChild(root: String, child: String, work: String) {
    if roots[root]?.children[child] == nil { roots[root]?.children[child] = work }
  }

  private mutating func suppressCompletedScreen(session: String) {
    if decision.logSessionID == session, roots[session]?.busy == false {
      suppressedSessionID = session
      suppressedScreen = screen
      suppressedContentID = screenContentID
    }
  }

  private func resolve(now: TimeInterval) -> AgentStateDecision {
    if let programStatus { return programStatus.decision }
    if let native, nativeAvailable {
      let suppressed = suppressedSessionID == native.sessionID && suppressedScreen == screen
      let blocked = native.state == .blocked || (screen.state == .blocked && !suppressed)
      return AgentStateDecision(
        state: blocked ? .blocked : native.state,
        reason: blocked && native.state != .blocked ? .screen(screen.reason) : .native(native.state),
        logSessionID: native.sessionID, hasOutstandingWork: native.state != .idle)
    }

    if let native, native.state == .idle,
      suppressedSessionID == native.sessionID, suppressedScreen == screen
    {
      return AgentStateDecision(state: .idle, reason: .fallback(.retainedCompletion))
    }
    let eligible = roots.filter { _, root in
      root.busy || root.lastActivity.map { now - $0 < activityWindow } == true
    }
    guard available, eligible.count == 1, let (id, root) = eligible.first else {
      // Expiry removes log authority, but does not make an unchanged completed
      // frame new evidence. Keep this fence scoped to the sole known root.
      if roots.count == 1,
        let id = roots.keys.first, roots[id]?.busy == false,
        suppressedSessionID == id, suppressedScreen == screen
      {
        return AgentStateDecision(state: .idle, reason: .fallback(.retainedCompletion))
      }
      let fallback: AgentScreenFallback =
        !available ? .logUnavailable : eligible.count > 1 ? .ambiguousLogs : .noLiveTurn
      return AgentStateDecision(
        state: stableScreen, reason: hasLogProvider ? .fallback(fallback) : .screen(screen.reason))
    }
    let suppressed = suppressedSessionID == id && suppressedScreen == screen
    if screen.state == .blocked, !suppressed {
      return AgentStateDecision(
        state: .blocked, reason: .screen(screen.reason), logSessionID: id,
        hasOutstandingWork: root.busy)
    }
    if root.busy {
      return AgentStateDecision(state: .working, reason: .logOpenWork, logSessionID: id, hasOutstandingWork: true)
    }
    // A turn end beats its retained frame, but cannot suppress a subsequent UI interaction.
    if !suppressed, screen.state == .working {
      return AgentStateDecision(state: .working, reason: .fallback(.afterTurn), logSessionID: id)
    }
    return AgentStateDecision(state: .idle, reason: .logTurnEnded, logSessionID: id)
  }
}
