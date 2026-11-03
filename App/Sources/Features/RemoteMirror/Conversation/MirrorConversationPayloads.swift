import Foundation

extension MirrorConversationEvent {
  /// Why a `session.changed` / `session.pending` event was sent.
  nonisolated enum SessionReason: String, Codable, Sendable {
    case clear
    case new
    case resume
    case fork
    /// The transcript file was replaced or truncated under the tail.
    case rotated
    /// The pane now drives another transcript; the Host does not know why.
    case switched
    /// The Host cannot tell which transcript the pane drives right now.
    case uncertain
  }

  nonisolated struct Session: Codable, Equatable, Sendable {
    var id: String?
    var cwd: String?
    var model: String?
    var title: String?
    var version: String?
    var costUSD: Double?
    var reason: SessionReason?
  }

  nonisolated enum MessageOrigin: String, Codable, Sendable {
    case human
    case queued
    case automation
    case system
    case other
  }

  nonisolated enum TurnStatus: String, Codable, Sendable {
    case completed
    case aborted
  }

  nonisolated struct Turn: Codable, Equatable, Sendable {
    var id: String?
    var origin: MessageOrigin?
    var status: TurnStatus?
    var durationMs: Int?
    var lastMessage: MirrorBoundedText?
    /// Why an aborted turn ended (`interrupted`, …), as the agent reports it.
    var reason: String?
  }

  nonisolated enum MessagePhase: String, Codable, Sendable {
    case commentary
    case final
  }

  nonisolated struct Message: Codable, Equatable, Sendable {
    var text: MirrorBoundedText
    var origin: MessageOrigin?
    var phase: MessagePhase?
    var images: Int?
    var model: String?
    /// For `user.unqueued`: why the queued message left the queue (`absorbed_mid_turn`, …).
    var reason: String?
  }

  nonisolated struct Reasoning: Codable, Equatable, Sendable {
    var durationMs: Int?
    var summary: MirrorBoundedText?
  }

  nonisolated enum ToolKind: String, Codable, Sendable {
    case shell
    case edit
    case read
    case search
    case web
    case mcp
    case agent
    case question
    case plan
    case skill
    case other
  }

  nonisolated struct ToolStart: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var kind: ToolKind
    var title: String
    var command: String?
    var path: String?
    var cwd: String?
    var background: Bool?
    var changedPaths: [String]?
  }

  nonisolated enum ToolStatus: String, Codable, Sendable {
    case succeeded
    case error
    case interrupted
  }

  nonisolated struct ToolEnd: Codable, Equatable, Sendable {
    var id: String
    var name: String?
    var status: ToolStatus
    var exitCode: Int?
    var output: MirrorBoundedText?
    /// A unified diff or added content for edits, bounded like output.
    var diff: MirrorBoundedText?
    var durationMs: Int?
    var isImage: Bool?
  }

  nonisolated enum AgentState: String, Codable, Sendable {
    case working
    case idle
    case blocked
    case unknown
  }

  nonisolated struct Status: Codable, Equatable, Sendable {
    var state: AgentState
    /// `permission`, `question`, `auth`, or `unspecified` while blocked.
    var kind: String?
    /// The Host's decision reason identifier, for diagnosis.
    var reason: String?
  }

  nonisolated enum PromptKind: String, Codable, Sendable {
    case permission
    case question
    case planApproval = "plan-approval"
    case auth
    case trust
    case elicitation
  }

  nonisolated enum PromptOutcome: String, Codable, Sendable {
    case allowed
    case denied
    case answered
    case dismissed
    case unknown
  }

  nonisolated struct Choice: Codable, Equatable, Sendable {
    var id: String
    var label: String
    var description: String?
  }

  nonisolated struct Question: Codable, Equatable, Sendable {
    var id: String
    var header: String?
    var question: String
    var multiSelect: Bool
    var options: [Choice]
  }

  nonisolated struct Prompt: Codable, Equatable, Sendable {
    var id: String
    var kind: PromptKind
    var title: String?
    var detail: MirrorBoundedText?
    var choices: [Choice]?
    var questions: [Question]?
    var freeform: Bool
    var outcome: PromptOutcome?
    var decidedBy: String?
  }

  nonisolated struct Subagent: Codable, Equatable, Sendable {
    var id: String?
    var type: String?
    var summary: MirrorBoundedText?
  }

  nonisolated enum NoticeLevel: String, Codable, Sendable {
    case info
    case warning
    case debug
  }

  nonisolated struct Notice: Codable, Equatable, Sendable {
    var level: NoticeLevel
    var text: String
    var subtype: String?
  }
}
