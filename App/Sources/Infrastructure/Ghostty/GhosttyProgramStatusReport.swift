import GhosttyKit

/// One OSC 7501 program status report, copied out of the libghostty action
/// while its strings are still valid: they live only for the callback.
nonisolated struct GhosttyProgramStatusReport: Equatable, Sendable {
  enum State: String, Equatable, Sendable {
    case idle
    case working
    case done
    case blocked
    case error
    /// Not a real state: remove the record with this id and every record
    /// beneath it. An empty id removes every record.
    case clear
  }

  /// What a blocked program needs from the user.
  enum Kind: String, Equatable, Sendable {
    case permission
    case question
    case auth
  }

  let state: State
  /// Only present for `.blocked`.
  let kind: Kind?
  /// 0 through 100; `nil` when the program sent none.
  let progress: Int?
  /// Empty for the root record. A `/` makes a record the child of another,
  /// so `build/test` is a child of `build`.
  let id: String
  /// A stable program name a machine can match on, such as `claude-code`.
  let app: String?
  let title: String?
  let message: String?

  init(
    state: State,
    kind: Kind? = nil,
    progress: Int? = nil,
    id: String = "",
    app: String? = nil,
    title: String? = nil,
    message: String? = nil
  ) {
    self.state = state
    self.kind = kind
    self.progress = progress
    self.id = id
    self.app = app
    self.title = title
    self.message = message
  }

  /// `nil` when libghostty reports a state this build does not know.
  init?(_ report: ghostty_action_program_status_s) {
    guard let state = State(report.state) else { return nil }
    self.init(
      state: state,
      kind: Kind(report.kind),
      progress: report.progress < 0 ? nil : Int(report.progress),
      id: Self.string(report.id) ?? "",
      app: Self.string(report.app),
      title: Self.string(report.title),
      message: Self.string(report.message)
    )
  }

  /// Absent text arrives as an empty string, never NULL.
  private static func string(_ pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    let value = String(cString: pointer)
    return value.isEmpty ? nil : value
  }
}

nonisolated extension GhosttyProgramStatusReport.State {
  init?(_ state: ghostty_action_program_status_state_e) {
    switch state {
    case GHOSTTY_PROGRAM_STATUS_STATE_IDLE: self = .idle
    case GHOSTTY_PROGRAM_STATUS_STATE_WORKING: self = .working
    case GHOSTTY_PROGRAM_STATUS_STATE_DONE: self = .done
    case GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED: self = .blocked
    case GHOSTTY_PROGRAM_STATUS_STATE_ERROR: self = .error
    case GHOSTTY_PROGRAM_STATUS_STATE_CLEAR: self = .clear
    default: return nil
    }
  }
}

nonisolated extension GhosttyProgramStatusReport.Kind {
  init?(_ kind: ghostty_action_program_status_kind_e) {
    switch kind {
    case GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION: self = .permission
    case GHOSTTY_PROGRAM_STATUS_KIND_QUESTION: self = .question
    case GHOSTTY_PROGRAM_STATUS_KIND_AUTH: self = .auth
    default: return nil
    }
  }
}
