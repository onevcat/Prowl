import Foundation

/// How far Prowl trusts a producer's OSC 7501 reports (docs-ai 079). A static table,
/// not a setting: a producer either reports or it does not, and a verified one is
/// trusted whenever it reports. The producer's own variables are the escape hatch.
nonisolated enum ProgramStatusSupport: Equatable, Sendable {
  /// Reports are stored, fenced, and resolved, but only compared with the live
  /// decision; disagreements are logged. The legacy decision is published.
  case unverified
  /// An eligible root record drives the decision and the schedule is delegated.
  case verified

  /// Slice 2 ships every agent unverified; slices 3 and 4 flip Claude and Pi after
  /// their baselines replay inside Prowl.
  static func level(for agent: DetectedAgent) -> ProgramStatusSupport {
    switch agent {
    default: .unverified
    }
  }
}

extension DetectedAgent {
  /// The `app` value the agent writes into its own records, or `nil` for agents
  /// without a known producer. `app` decides whose state a record is, never whether
  /// it is authentic.
  nonisolated var programStatusApp: String? {
    switch self {
    case .claude: "claude-code"
    case .pi: "pi"
    default: nil
    }
  }
}

/// The reason a decision is OSC-driven; `identifier` is the public `detection_reason`.
nonisolated enum ProgramStatusReason: Equatable, Sendable {
  case working
  case blocked(GhosttyProgramStatusReport.Kind?)
  case idle
  case done
  case error
  case childBlocked(GhosttyProgramStatusReport.Kind?)

  var identifier: String {
    switch self {
    case .working: "osc.working"
    case .blocked(let kind): "osc.blocked.\(kind?.rawValue ?? "unspecified")"
    case .idle: "osc.idle"
    case .done: "osc.done"
    case .error: "osc.error"
    case .childBlocked(let kind): "osc.childBlocked.\(kind?.rawValue ?? "unspecified")"
    }
  }

  /// `done` and `error` leave a result to look at; `idle` is sent at mount, on
  /// interrupt, and on a session reset, none of which does.
  var earnsDoneBadge: Bool {
    switch self {
    case .done, .error: true
    case .working, .blocked, .idle, .childBlocked: false
    }
  }
}

/// What the eligible records of one surface say about its agent: the root's state and
/// whether an eligible child is blocked. Child `working` is deliberately absent: the
/// pane follows the root only (decision of 2026-10-10).
nonisolated struct ProgramStatusEvidence: Equatable, Sendable {
  struct BlockedChild: Equatable, Sendable {
    let kind: GhosttyProgramStatusReport.Kind?
  }

  let root: ProgramStatusRecord.State
  let rootKind: GhosttyProgramStatusReport.Kind?
  let blockedChild: BlockedChild?

  init(
    root: ProgramStatusRecord.State, rootKind: GhosttyProgramStatusReport.Kind? = nil, blockedChild: BlockedChild? = nil
  ) {
    self.root = root
    self.rootKind = rootKind
    self.blockedChild = blockedChild
  }

  /// The attribution fence. A record is eligible when its `app` (after inheritance)
  /// equals the agent's `programStatusApp` and it arrived no earlier than the detected
  /// process started; a root record is required. The fence is attribution, not trust.
  init?(store: ProgramStatusRecordStore, app: String, notBefore: Date) {
    func eligible(_ record: ProgramStatusRecord) -> Bool {
      store.app(of: record) == app && record.arrivedAt >= notBefore
    }
    guard let root = store.root, eligible(root) else { return nil }
    let blocked = store.children.first { $0.state == .blocked && eligible($0) }
    self.init(
      root: root.state,
      rootKind: root.state == .blocked ? root.kind : nil,
      blockedChild: blocked.map { BlockedChild(kind: $0.kind) })
  }

  /// The pure mapping from evidence to decision; shared by the state machine and the
  /// shadow comparison of unverified producers. `screenReason` is left to the caller.
  var decision: AgentStateDecision {
    switch root {
    case .blocked:
      return AgentStateDecision(state: .blocked, reason: .programStatus(.blocked(rootKind)), hasOutstandingWork: true)
    case .working, .idle, .done, .error:
      if let blockedChild {
        return AgentStateDecision(
          state: .blocked, reason: .programStatus(.childBlocked(blockedChild.kind)), hasOutstandingWork: true)
      }
    }
    switch root {
    case .working:
      return AgentStateDecision(state: .working, reason: .programStatus(.working), hasOutstandingWork: true)
    case .idle:
      return AgentStateDecision(state: .idle, reason: .programStatus(.idle))
    case .done:
      return AgentStateDecision(state: .idle, reason: .programStatus(.done))
    case .error:
      return AgentStateDecision(state: .idle, reason: .programStatus(.error))
    case .blocked:
      return AgentStateDecision(state: .blocked, reason: .programStatus(.blocked(rootKind)), hasOutstandingWork: true)
    }
  }
}
