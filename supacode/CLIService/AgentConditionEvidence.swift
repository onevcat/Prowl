import Foundation
import ProwlCLIShared

/// The per-poll view of one pane that condition evidence is evaluated against.
struct AgentConditionSnapshot: Sendable {
  let agent: ActiveAgentEntry?
  /// Active terminal evidence for idle, blocked, and exit conditions.
  let signal: AgentSignal?
  /// Latest current-epoch signal used only to detect a post-baseline change.
  let changedSignal: AgentSignal?
  let revision: UInt64
  let isLive: Bool
  let signals: AgentSignalsPayload

  init(
    agent: ActiveAgentEntry?,
    signal: AgentSignal?,
    changedSignal: AgentSignal? = nil,
    revision: UInt64,
    isLive: Bool,
    signals: AgentSignalsPayload
  ) {
    self.agent = agent
    self.signal = signal
    self.changedSignal = changedSignal ?? signal
    self.revision = revision
    self.isLive = isLive
    self.signals = signals
  }
}

/// The evidence rules shared by `agents wait <pane> --until …` and the idle precondition of
/// `agents dispatch` (064.012/013). Keeping them in one place means a re-dispatch accepts
/// exactly the pane states an `--until idle` wait would resolve, and refuses the rest.
@MainActor
enum AgentConditionEvidence {
  /// What a wait saw when it was armed; a re-dispatch evaluates against the current snapshot
  /// itself, so every signal it sees is a pre-arm level.
  struct Baseline: Sendable {
    let revision: UInt64
    let changedSignal: AgentSignal?
    /// Terminal evidence that already existed when the wait was armed; it satisfies `idle` or
    /// `blocked` only with detector corroboration, so a stale level cannot end a fresh wait.
    let terminalSignal: AgentSignal?
    let state: String

    init(revision: UInt64, changedSignal: AgentSignal?, terminalSignal: AgentSignal?, state: String) {
      self.revision = revision
      self.changedSignal = changedSignal
      self.terminalSignal = terminalSignal
      self.state = state
    }

    init(snapshot: AgentConditionSnapshot) {
      self.init(
        revision: snapshot.revision,
        changedSignal: snapshot.changedSignal,
        terminalSignal: snapshot.signal,
        state: AgentConditionEvidence.normalizedState(snapshot)
      )
    }
  }

  /// Tracks how long a heuristic candidate state has been unchanged; `auto` accepts it only
  /// after two seconds so a transient screen never resolves a wait.
  struct HeuristicStabilizer {
    static let requiredMilliseconds = 2_000

    private var state: String?
    private var sinceMilliseconds = 0

    init() {}

    mutating func observe(candidate: String?, elapsedMilliseconds: Int) -> Bool {
      guard let candidate else {
        state = nil
        return false
      }
      if state != candidate {
        state = candidate
        sinceMilliseconds = elapsedMilliseconds
        return false
      }
      return elapsedMilliseconds - sinceMilliseconds >= Self.requiredMilliseconds
    }
  }

  /// The arm-time verdict of `agents wait --until idle` under `auto`, shared by `agents dispatch`
  /// and the workflow runner's idle wait (docs-ai 064.014 D5, 063 B3).
  enum IdleVerdict: Equatable {
    case idle
    /// Idle by one source only; the caller keeps polling (and stabilizes a detector-only view).
    case settling(String)
    case busy(String)
  }

  /// A pre-arm `turn-ended` counts only with detector corroboration, and the detector alone
  /// counts only where the wait would fall back to it. Either source alone is not a refusal yet;
  /// working or blocked without such evidence is.
  static func idleVerdict(
    for snapshot: AgentConditionSnapshot, baseline explicitBaseline: Baseline? = nil
  ) -> IdleVerdict {
    let state = normalizedState(snapshot)
    // Without a baseline every signal the snapshot holds predates this call (the re-dispatch
    // case); a wait that keeps polling passes the baseline it armed with, so a later exact
    // `turn-ended` counts even while the screen still shows `working`.
    let baseline = explicitBaseline ?? Baseline(snapshot: snapshot)
    if exactMatch(
      condition: .idle, snapshot: snapshot, normalizedState: state, baseline: baseline, minimumConfidence: .auto)
      != nil
    {
      return .idle
    }
    if detectorReports(.idle, normalizedState: state), allowsHeuristic(.auto, condition: .idle, snapshot: snapshot) {
      return .settling(state)
    }
    if let signal = snapshot.signal, signal.event == .turnEnded, accepts(signal.confidence, minimum: .auto),
      !detectorReports(.blocked, normalizedState: state)
    {
      return .settling(state)
    }
    return .busy(state)
  }

  static func normalizedState(_ snapshot: AgentConditionSnapshot) -> String {
    guard snapshot.isLive else { return "gone" }
    return snapshot.agent.map { status(for: $0, fallback: .idle).rawValue } ?? "absent"
  }

  static func status(for agent: ActiveAgentEntry?, fallback: AgentsCommandStatus) -> AgentsCommandStatus {
    agent.flatMap { AgentsCommandStatus(rawValue: $0.displayState.rawValue) } ?? fallback
  }

  /// Whether the screen detector currently reports the requested `idle` or `blocked` condition.
  static func detectorReports(_ condition: AgentWaitCondition, normalizedState: String) -> Bool {
    switch condition {
    case .idle:
      normalizedState == AgentsCommandStatus.idle.rawValue || normalizedState == AgentsCommandStatus.done.rawValue
    case .blocked:
      normalizedState == AgentsCommandStatus.blocked.rawValue
    case .changed, .exit:
      false
    }
  }

  static func accepts(_ confidence: AgentSignal.Confidence, minimum: AgentWaitMinimumConfidence) -> Bool {
    switch minimum {
    case .auto, .high: confidence == .exact || confidence == .high
    case .exact: confidence == .exact
    case .heuristic: true
    }
  }

  /// The signal that satisfies `condition` exactly, or nil. A terminal level that predates the
  /// baseline counts for `idle`/`blocked` only when the detector corroborates it.
  static func exactMatch(
    condition: AgentWaitCondition,
    snapshot: AgentConditionSnapshot,
    normalizedState: String,
    baseline: Baseline,
    minimumConfidence: AgentWaitMinimumConfidence
  ) -> AgentSignal? {
    let signal = condition == .changed ? snapshot.changedSignal : snapshot.signal
    guard let signal, accepts(signal.confidence, minimum: minimumConfidence) else { return nil }
    let isPreArmLevel = condition != .changed && signal == baseline.terminalSignal
    let matches =
      switch condition {
      case .idle:
        signal.event == .turnEnded && (!isPreArmLevel || detectorReports(.idle, normalizedState: normalizedState))
      case .blocked:
        signal.event == .needsInput
          && (!isPreArmLevel || detectorReports(.blocked, normalizedState: normalizedState))
      case .changed: snapshot.revision > baseline.revision && signal != baseline.changedSignal
      case .exit: signal.event == .sessionEnd
      }
    return matches ? signal : nil
  }

  /// Whether `auto` may fall back to the stabilized screen detector. A covering `verified_live`
  /// channel reports the next edge itself (`changed`) and its own `session-end` (`exit`), so
  /// those never fall back; a channel that cannot report `session-end` (Codex's notifier,
  /// OpenCode's relay) leaves `exit` to the detector, the only exit evidence once `/quit` has
  /// returned the shell on a still-live surface. For `idle` and `blocked` the channel is
  /// authoritative while it holds any terminal level: the condition's own event resolves
  /// through the exact path, and an opposite event means the runtime disagrees with the
  /// screen, which a stabilized detector view must not override. Only a channel with no
  /// terminal level yet — a freshly launched, unprompted Profile that has reported
  /// `session-start` alone — leaves the current state to the detector.
  static func allowsHeuristic(
    _ minimum: AgentWaitMinimumConfidence,
    condition: AgentWaitCondition,
    snapshot: AgentConditionSnapshot
  ) -> Bool {
    switch minimum {
    case .exact, .high:
      return false
    case .heuristic:
      return true
    case .auto:
      let coveredEvent: AgentSignalEvent =
        switch condition {
        case .idle: .turnEnded
        case .blocked: .needsInput
        case .exit: .sessionEnd
        case .changed: .progress
        }
      let liveChannelCovers = snapshot.signals.channels.contains {
        $0.state == .verifiedLive && (condition == .changed || $0.events.contains(coveredEvent))
      }
      guard liveChannelCovers else { return true }
      switch condition {
      case .changed, .exit:
        return false
      case .idle, .blocked:
        return snapshot.signal == nil
      }
    }
  }

  static func heuristicMatches(
    condition: AgentWaitCondition,
    snapshot: AgentConditionSnapshot,
    normalizedState: String,
    baseline: Baseline
  ) -> Bool {
    switch condition {
    case .idle, .blocked: detectorReports(condition, normalizedState: normalizedState)
    case .changed: snapshot.revision > baseline.revision && normalizedState != baseline.state
    case .exit: !snapshot.isLive || snapshot.agent == nil
    }
  }
}
