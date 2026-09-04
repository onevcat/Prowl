import Foundation

struct PaneAgentState: Equatable, Sendable {
  var detectedAgent: DetectedAgent?
  var agentProcessID: pid_t?
  /// The process the shell launched for the agent, which may differ from
  /// `agentProcessID` once the runtime forks an engine child. Process
  /// generations key on this so such a child is not mistaken for a relaunch.
  var launchProcessID: pid_t?
  var launchObservation: AgentLaunchObservation?
  var session: AgentSession?
  /// Consecutive resolver misses while the same process stayed detected;
  /// bounds how long a previously resolved session may be retained.
  var sessionMissStreak: Int = 0
  var iconLookupToken: String?
  var fallbackState: AgentRawState
  var state: AgentRawState
  var seen: Bool
  var lastChangedAt: Date

  init(
    detectedAgent: DetectedAgent? = nil,
    agentProcessID: pid_t? = nil,
    launchProcessID: pid_t? = nil,
    launchObservation: AgentLaunchObservation? = nil,
    session: AgentSession? = nil,
    iconLookupToken: String? = nil,
    fallbackState: AgentRawState = .unknown,
    state: AgentRawState = .unknown,
    seen: Bool = true,
    lastChangedAt: Date = Date()
  ) {
    self.detectedAgent = detectedAgent
    self.agentProcessID = agentProcessID
    self.launchProcessID = launchProcessID
    self.launchObservation = launchObservation
    self.session = session
    self.iconLookupToken = iconLookupToken
    self.fallbackState = fallbackState
    self.state = state
    self.seen = seen
    self.lastChangedAt = lastChangedAt
  }

  /// Sticky-session policy: a resolution always wins; a probe gap
  /// (`identifiedPID == nil`, presence hold) keeps the last session without
  /// aging it; a FRESH ambiguous resolution on the same process keeps it for
  /// at most two misses so a rotated-away session id cannot survive
  /// indefinitely. Cache replays during resolver backoff (`isFresh == false`)
  /// are not new evidence and never age the session. A different pid discards
  /// it immediately.
  static func retainedSession(
    resolved: AgentSession?,
    isFresh: Bool,
    previous: PaneAgentState,
    identifiedPID: pid_t?
  ) -> (session: AgentSession?, missStreak: Int) {
    if let resolved { return (resolved, 0) }
    guard let identifiedPID else { return (previous.session, previous.sessionMissStreak) }
    guard identifiedPID == previous.agentProcessID else { return (nil, 0) }
    guard isFresh else { return (previous.session, previous.sessionMissStreak) }
    let streak = previous.sessionMissStreak + 1
    return (streak >= 3 ? nil : previous.session, streak)
  }

  /// Launch-process stickiness: the launch process is the generation subject for managed hooks,
  /// so a transient sample that drops it from the foreground job must not read as a relaunch.
  /// A full probe gap (no agent identified) keeps the previous value; when the identified root
  /// changes, keep the previous one only while it is still a live ancestor of the identified
  /// process — otherwise the launch genuinely moved and the new root wins.
  static func retainedLaunchProcessID(
    identifiedLaunchProcessID: pid_t?,
    identifiedProcessID: pid_t?,
    previous: PaneAgentState,
    isLiveAncestor: (_ ancestor: pid_t, _ descendant: pid_t) -> Bool
  ) -> pid_t? {
    guard let candidate = identifiedLaunchProcessID else { return previous.launchProcessID }
    guard let previousLaunch = previous.launchProcessID,
      previousLaunch != candidate,
      let identifiedProcessID
    else { return candidate }
    return isLiveAncestor(previousLaunch, identifiedProcessID) ? previousLaunch : candidate
  }

  /// An argv observation is usable only while it belongs to the same detected
  /// process. Unlike sessions, an absent probe never proves a safer mode.
  static func retainedLaunchObservation(
    observed: AgentLaunchObservation?,
    previous: PaneAgentState,
    identifiedPID: pid_t?
  ) -> AgentLaunchObservation? {
    if let observed { return observed }
    guard let identifiedPID, identifiedPID == previous.agentProcessID else { return nil }
    return previous.launchObservation
  }

  var displayState: AgentDisplayState {
    switch state {
    case .working:
      return .working
    case .blocked:
      return .blocked
    case .idle:
      return seen ? .idle : .done
    case .unknown:
      return .idle
    }
  }

  /// Whether this pane should count toward the worktree running indicator: a
  /// detected agent that is working or blocked (awaiting permission). Folded
  /// into `taskStatus` so the sidebar spinner and `prowl list` light up on agent
  /// activity even when no OSC 9;4 command progress is reported (Claude Code
  /// does not emit OSC 9;4 while it works).
  var isBusy: Bool {
    guard detectedAgent != nil else { return false }
    return displayState == .working || displayState == .blocked
  }

  /// The `.blocked` slice of `isBusy`: the agent has stopped and is waiting on
  /// an answer (permission prompt, AskUserQuestion). Tracked separately so the
  /// sidebar can distinguish "wait for it" from "it is waiting for you".
  var isBlocked: Bool {
    guard detectedAgent != nil else { return false }
    return displayState == .blocked
  }
}

struct AgentDetectionPresence: Equatable, Sendable {
  static let releaseMissThreshold = 6

  var currentAgent: DetectedAgent?
  var consecutiveMisses: UInt8

  init(currentAgent: DetectedAgent? = nil, consecutiveMisses: UInt8 = 0) {
    self.currentAgent = currentAgent
    self.consecutiveMisses = consecutiveMisses
  }

  mutating func update(detectedAgent: DetectedAgent?) -> DetectedAgent? {
    if let detectedAgent {
      currentAgent = detectedAgent
      consecutiveMisses = 0
      return detectedAgent
    }

    guard currentAgent != nil else {
      consecutiveMisses = 0
      return nil
    }

    consecutiveMisses = min(consecutiveMisses + 1, UInt8(Self.releaseMissThreshold))
    if consecutiveMisses >= Self.releaseMissThreshold {
      currentAgent = nil
      consecutiveMisses = 0
    }
    return currentAgent
  }
}

func stabilizeAgentState(
  agent: DetectedAgent?,
  previous: AgentRawState,
  raw: AgentRawState
) -> AgentRawState {
  guard agent != nil else { return raw }

  switch raw {
  case .unknown:
    // A viewer overlay (transcript, history search) is covering the live
    // status area, so this frame carries no signal: keep the last trusted state.
    return previous
  case .working, .blocked, .idle:
    return raw
  }
}
