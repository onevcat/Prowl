import Foundation

public struct AgentSignalCommandPayload: Codable, Equatable, Sendable {
  public let pane: AgentSignalPanePayload
  public let signal: AgentSignalPayload
  /// Omitted when empty; present only when the receipt carries a caveat such as `signal_unbound`.
  public let warnings: [AgentSignalWarning]?

  public init(pane: AgentSignalPanePayload, signal: AgentSignalPayload, warnings: [AgentSignalWarning] = []) {
    self.pane = pane
    self.signal = signal
    self.warnings = warnings.isEmpty ? nil : warnings
  }
}

nonisolated public enum AgentSignalWarningCode: String, Codable, Sendable {
  case signalUnbound = "signal_unbound"
}

nonisolated public struct AgentSignalWarning: Codable, Sendable, Equatable {
  public let code: AgentSignalWarningCode
  public let message: String

  public init(code: AgentSignalWarningCode, message: String) {
    self.code = code
    self.message = message
  }
}

public struct AgentSignalPanePayload: Codable, Equatable, Sendable {
  public let id: String
  public let worktreeID: String

  enum CodingKeys: String, CodingKey {
    case id
    case worktreeID = "worktree_id"
  }

  public init(id: String, worktreeID: String) {
    self.id = id
    self.worktreeID = worktreeID
  }
}

public struct AgentSignalPayload: Codable, Equatable, Sendable {
  public let event: AgentSignalEvent
  public let progress: Int?
  public let source: String
  public let confidence: String
  /// Whether the signal bound to the pane's current agent generation. Only a `current` signal
  /// becomes wait or dispatch evidence; an `unbound` one is retained as diagnostics. Absent when
  /// an older app produced the receipt.
  public let binding: AgentSignalBinding?
  public let timestamp: String
  public let sessionID: String?
  public let detail: String?
  public let claimedOrigin: String?

  enum CodingKeys: String, CodingKey {
    case event
    case progress
    case source
    case confidence
    case binding
    case timestamp = "at"
    case sessionID = "session_id"
    case detail
    case claimedOrigin = "claimed_origin"
  }

  public init(
    event: AgentSignalEvent,
    progress: Int?,
    source: String,
    confidence: String,
    binding: AgentSignalBinding? = nil,
    timestamp: String,
    sessionID: String?,
    detail: String?,
    claimedOrigin: String?
  ) {
    self.event = event
    self.progress = progress
    self.source = source
    self.confidence = confidence
    self.binding = binding
    self.timestamp = timestamp
    self.sessionID = sessionID
    self.detail = detail
    self.claimedOrigin = claimedOrigin
  }
}
