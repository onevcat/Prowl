import Foundation

public struct AgentReadCommandPayload: Codable, Equatable, Sendable {
  public let outputMode: AgentReadOutputMode
  public let target: ReadTarget
  public let agent: AgentReadAgent
  public let blocker: AgentReadBlocker?
  public let result: AgentReadResult

  enum CodingKeys: String, CodingKey {
    case outputMode = "output_mode"
    case target
    case agent
    case blocker
    case result
  }

  public init(
    outputMode: AgentReadOutputMode,
    target: ReadTarget,
    agent: AgentReadAgent,
    blocker: AgentReadBlocker?,
    result: AgentReadResult
  ) {
    self.outputMode = outputMode
    self.target = target
    self.agent = agent
    self.blocker = blocker
    self.result = result
  }
}

public enum AgentReadOutputMode: String, Codable, Equatable, Sendable {
  case snapshot
  case resultOnly = "result_only"
}

public struct AgentReadAgent: Codable, Equatable, Sendable {
  public let type: String
  public let status: AgentsCommandStatus
  public let rawState: String
  public let detectionReason: String?
  public let screenReason: String?
  public let lastChangedAt: String
  public let session: AgentReadSession?

  enum CodingKeys: String, CodingKey {
    case type
    case status
    case rawState = "raw_state"
    case detectionReason = "detection_reason"
    case screenReason = "screen_reason"
    case lastChangedAt = "last_changed_at"
    case session
  }

  public init(
    type: String,
    status: AgentsCommandStatus,
    rawState: String,
    detectionReason: String?,
    screenReason: String? = nil,
    lastChangedAt: String,
    session: AgentReadSession?
  ) {
    self.type = type
    self.status = status
    self.rawState = rawState
    self.detectionReason = detectionReason
    self.screenReason = screenReason
    self.lastChangedAt = lastChangedAt
    self.session = session
  }
}

public struct AgentReadSession: Codable, Equatable, Sendable {
  public let id: String
  public let confidence: String
  public let source: String

  public init(id: String, confidence: String, source: String) {
    self.id = id
    self.confidence = confidence
    self.source = source
  }
}

public struct AgentReadBlocker: Codable, Equatable, Sendable {
  public let text: String

  public init(text: String) {
    self.text = text
  }
}

public struct AgentReadResult: Codable, Equatable, Sendable {
  public let state: AgentReadResultState
  public let text: String?
  public let error: AgentReadResultError?

  public init(state: AgentReadResultState, text: String? = nil, error: AgentReadResultError? = nil) {
    self.state = state
    self.text = text
    self.error = error
  }
}

public enum AgentReadResultState: String, Codable, Equatable, Sendable {
  case complete
  case pending
  case unavailable
  case missing
  case incomplete
  case tooLarge = "too_large"
}

public struct AgentReadResultError: Codable, Equatable, Sendable {
  public let code: String
  public let message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}
