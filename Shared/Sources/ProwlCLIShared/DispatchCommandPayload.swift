import Foundation

public enum DispatchRecordState: String, Codable, Sendable {
  case pending
  case completed
  case gone
  case abandoned
}

public enum DispatchGoneReason: String, Codable, Sendable {
  case sessionEnd = "session_end"
  case surfaceClosed = "surface_closed"
}

public struct DispatchPendingRecord: Codable, Equatable, Sendable {
  public let id: String
  public let state: DispatchRecordState
  public let createdAt: String

  enum CodingKeys: String, CodingKey {
    case id
    case state
    case createdAt = "created_at"
  }

  public init(id: String, createdAt: String) {
    self.id = id
    self.state = .pending
    self.createdAt = createdAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.state = try container.decode(DispatchRecordState.self, forKey: .state)
    self.createdAt = try container.decode(String.self, forKey: .createdAt)
    guard state == .pending else {
      throw DecodingError.dataCorruptedError(
        forKey: .state,
        in: container,
        debugDescription: "Pending dispatch record must use state=pending."
      )
    }
  }
}

public struct DispatchCompletedRecord: Codable, Equatable, Sendable {
  public let id: String
  public let state: DispatchRecordState
  public let outcome: DispatchCompletionOutcome
  public let summary: String
  public let createdAt: String
  public let completedAt: String

  enum CodingKeys: String, CodingKey {
    case id
    case state
    case outcome
    case summary
    case createdAt = "created_at"
    case completedAt = "completed_at"
  }

  public init(
    id: String,
    outcome: DispatchCompletionOutcome,
    summary: String,
    createdAt: String,
    completedAt: String
  ) {
    self.id = id
    self.state = .completed
    self.outcome = outcome
    self.summary = summary
    self.createdAt = createdAt
    self.completedAt = completedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.state = try container.decode(DispatchRecordState.self, forKey: .state)
    self.outcome = try container.decode(DispatchCompletionOutcome.self, forKey: .outcome)
    self.summary = try container.decode(String.self, forKey: .summary)
    self.createdAt = try container.decode(String.self, forKey: .createdAt)
    self.completedAt = try container.decode(String.self, forKey: .completedAt)
    guard state == .completed else {
      throw DecodingError.dataCorruptedError(
        forKey: .state,
        in: container,
        debugDescription: "Completed dispatch record must use state=completed."
      )
    }
  }
}

public struct DispatchGoneRecord: Codable, Equatable, Sendable {
  public let id: String
  public let state: DispatchRecordState
  public let createdAt: String
  public let goneAt: String
  public let reason: DispatchGoneReason

  enum CodingKeys: String, CodingKey {
    case id
    case state
    case createdAt = "created_at"
    case goneAt = "gone_at"
    case reason = "gone_reason"
  }

  public init(id: String, createdAt: String, goneAt: String, reason: DispatchGoneReason) {
    self.id = id
    self.state = .gone
    self.createdAt = createdAt
    self.goneAt = goneAt
    self.reason = reason
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.state = try container.decode(DispatchRecordState.self, forKey: .state)
    self.createdAt = try container.decode(String.self, forKey: .createdAt)
    self.goneAt = try container.decode(String.self, forKey: .goneAt)
    self.reason = try container.decode(DispatchGoneReason.self, forKey: .reason)
    guard state == .gone else {
      throw DecodingError.dataCorruptedError(
        forKey: .state,
        in: container,
        debugDescription: "Gone dispatch record must use state=gone."
      )
    }
  }
}

public struct DispatchAbandonedRecord: Codable, Equatable, Sendable {
  public let id: String
  public let state: DispatchRecordState
  public let createdAt: String
  public let abandonedAt: String
  public let reason: String

  enum CodingKeys: String, CodingKey {
    case id
    case state
    case createdAt = "created_at"
    case abandonedAt = "abandoned_at"
    case reason
  }

  public init(id: String, createdAt: String, abandonedAt: String, reason: String) {
    self.id = id
    self.state = .abandoned
    self.createdAt = createdAt
    self.abandonedAt = abandonedAt
    self.reason = reason
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.state = try container.decode(DispatchRecordState.self, forKey: .state)
    self.createdAt = try container.decode(String.self, forKey: .createdAt)
    self.abandonedAt = try container.decode(String.self, forKey: .abandonedAt)
    self.reason = try container.decode(String.self, forKey: .reason)
    guard state == .abandoned else {
      throw DecodingError.dataCorruptedError(
        forKey: .state,
        in: container,
        debugDescription: "Abandoned dispatch record must use state=abandoned."
      )
    }
  }
}

public enum DispatchRecordPayload: Codable, Equatable, Sendable {
  case pending(DispatchPendingRecord)
  case completed(DispatchCompletedRecord)
  case gone(DispatchGoneRecord)
  case abandoned(DispatchAbandonedRecord)

  public var id: String {
    switch self {
    case .pending(let record): record.id
    case .completed(let record): record.id
    case .gone(let record): record.id
    case .abandoned(let record): record.id
    }
  }

  public var state: DispatchRecordState {
    switch self {
    case .pending: .pending
    case .completed: .completed
    case .gone: .gone
    case .abandoned: .abandoned
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    let stateKey = DynamicCodingKey("state")
    let state = try container.decode(DispatchRecordState.self, forKey: stateKey)
    let actualKeys = Set(container.allKeys.map(\.stringValue))
    let expectedKeys: Set<String>
    switch state {
    case .pending:
      expectedKeys = ["id", "state", "created_at"]
    case .completed:
      expectedKeys = ["id", "state", "outcome", "summary", "created_at", "completed_at"]
    case .gone:
      expectedKeys = ["id", "state", "created_at", "gone_at", "gone_reason"]
    case .abandoned:
      expectedKeys = ["id", "state", "created_at", "abandoned_at", "reason"]
    }
    guard actualKeys == expectedKeys else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "Dispatch record fields do not match its tagged state."
        )
      )
    }
    switch state {
    case .pending:
      self = .pending(try DispatchPendingRecord(from: decoder))
    case .completed:
      self = .completed(try DispatchCompletedRecord(from: decoder))
    case .gone:
      self = .gone(try DispatchGoneRecord(from: decoder))
    case .abandoned:
      self = .abandoned(try DispatchAbandonedRecord(from: decoder))
    }
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .pending(let record): try record.encode(to: encoder)
    case .completed(let record): try record.encode(to: encoder)
    case .gone(let record): try record.encode(to: encoder)
    case .abandoned(let record): try record.encode(to: encoder)
    }
  }
}

public enum AgentSignalChannelState: String, Codable, Sendable {
  case observed
  case verifiedLive = "verified_live"
}

public enum AgentSignalBinding: String, Codable, Sendable {
  case current
  case unbound
  case stale
}

public struct AgentSignalChannelPayload: Codable, Equatable, Sendable {
  public let source: String
  public let state: AgentSignalChannelState
  public let confidence: String
  public let events: [AgentSignalEvent]
  public let lastSeenAt: String
  public let sessionID: String?

  enum CodingKeys: String, CodingKey {
    case source
    case state
    case confidence
    case events
    case lastSeenAt = "last_seen_at"
    case sessionID = "session_id"
  }

  public init(
    source: String,
    state: AgentSignalChannelState,
    confidence: String,
    events: [AgentSignalEvent],
    lastSeenAt: String,
    sessionID: String? = nil
  ) {
    self.source = source
    self.state = state
    self.confidence = confidence
    self.events = events
    self.lastSeenAt = lastSeenAt
    self.sessionID = sessionID
  }
}

public struct AgentSignalsPayload: Codable, Equatable, Sendable {
  public let channels: [AgentSignalChannelPayload]
  public let last: AgentSignalPayload?
  public let lastBinding: AgentSignalBinding?

  enum CodingKeys: String, CodingKey {
    case channels
    case last
    case lastBinding = "last_binding"
  }

  public init(
    channels: [AgentSignalChannelPayload],
    last: AgentSignalPayload?,
    lastBinding: AgentSignalBinding?
  ) {
    self.channels = channels
    self.last = last
    self.lastBinding = lastBinding
  }
}

/// `agents.dispatch` success: the immutable target snapshot and the new pending record,
/// shaped like the `create` response so coordinators consume both the same way.
public struct AgentDispatchCommandPayload: Codable, Equatable, Sendable {
  public let target: TabTarget
  public let dispatch: DispatchPendingRecord

  public init(target: TabTarget, dispatch: DispatchPendingRecord) {
    self.target = target
    self.dispatch = dispatch
  }
}

/// Governed `error.details` for a refused `agents.dispatch`: `record` carries the pane's
/// current pending dispatch (`DISPATCH_PENDING`); `observation` and `signals` carry the
/// evidence that made the pane busy or agent-less.
public struct AgentDispatchErrorDetails: Codable, Equatable, Sendable {
  public let target: TabTarget
  public let record: DispatchRecordPayload?
  public let observation: AgentWaitObservation?
  public let signals: AgentSignalsPayload?

  public init(
    target: TabTarget,
    record: DispatchRecordPayload? = nil,
    observation: AgentWaitObservation? = nil,
    signals: AgentSignalsPayload? = nil
  ) {
    self.target = target
    self.record = record
    self.observation = observation
    self.signals = signals
  }
}

public struct DispatchCompleteCommandPayload: Codable, Equatable, Sendable {
  public let target: TabTarget
  public let receipt: DispatchCompletedRecord
  public let replayed: Bool

  public init(target: TabTarget, receipt: DispatchCompletedRecord, replayed: Bool) {
    self.target = target
    self.receipt = receipt
    self.replayed = replayed
  }
}

public struct DispatchAbandonCommandPayload: Codable, Equatable, Sendable {
  public let target: TabTarget
  public let record: DispatchAbandonedRecord
  public let replayed: Bool

  public init(target: TabTarget, record: DispatchAbandonedRecord, replayed: Bool) {
    self.target = target
    self.record = record
    self.replayed = replayed
  }
}

public struct AgentWaitObservation: Codable, Equatable, Sendable {
  public let status: AgentsCommandStatus
  public let rawState: String
  public let source: String
  public let confidence: String
  public let timestamp: String
  public let revision: Int

  enum CodingKeys: String, CodingKey {
    case status
    case rawState = "raw_state"
    case source
    case confidence
    case timestamp = "at"
    case revision
  }

  public init(
    status: AgentsCommandStatus,
    rawState: String,
    source: String,
    confidence: String,
    timestamp: String,
    revision: Int
  ) {
    self.status = status
    self.rawState = rawState
    self.source = source
    self.confidence = confidence
    self.timestamp = timestamp
    self.revision = revision
  }
}

public enum AgentWaitScreenPayload: Codable, Equatable, Sendable {
  case captured(AgentWaitCapturedScreen)
  case unavailable(AgentWaitUnavailableScreen)

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    let status = try container.decode(String.self, forKey: DynamicCodingKey("status"))
    switch status {
    case "captured":
      try requireExactKeys(
        container,
        ["status", "requested_lines", "source", "waited_ms", "text", "line_count", "stabilized"],
        decoder: decoder
      )
      self = .captured(try AgentWaitCapturedScreen(from: decoder))
    case "unavailable":
      try requireExactKeys(
        container,
        ["status", "requested_lines", "source", "waited_ms"],
        decoder: decoder
      )
      self = .unavailable(try AgentWaitUnavailableScreen(from: decoder))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: DynamicCodingKey("status"),
        in: container,
        debugDescription: "Unknown screen capture status."
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .captured(let screen): try screen.encode(to: encoder)
    case .unavailable(let screen): try screen.encode(to: encoder)
    }
  }
}

public struct AgentWaitCapturedScreen: Codable, Equatable, Sendable {
  public let status = "captured"
  public let requestedLines: Int
  public let source = "detection"
  public let waitedMilliseconds: Int
  public let text: String
  public let lineCount: Int
  public let stabilized: Bool

  enum CodingKeys: String, CodingKey {
    case status
    case requestedLines = "requested_lines"
    case source
    case waitedMilliseconds = "waited_ms"
    case text
    case lineCount = "line_count"
    case stabilized
  }

  public init(
    requestedLines: Int,
    waitedMilliseconds: Int,
    text: String,
    lineCount: Int,
    stabilized: Bool
  ) {
    self.requestedLines = requestedLines
    self.waitedMilliseconds = waitedMilliseconds
    self.text = text
    self.lineCount = lineCount
    self.stabilized = stabilized
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let status = try container.decode(String.self, forKey: .status)
    self.requestedLines = try container.decode(Int.self, forKey: .requestedLines)
    let source = try container.decode(String.self, forKey: .source)
    self.waitedMilliseconds = try container.decode(Int.self, forKey: .waitedMilliseconds)
    self.text = try container.decode(String.self, forKey: .text)
    self.lineCount = try container.decode(Int.self, forKey: .lineCount)
    self.stabilized = try container.decode(Bool.self, forKey: .stabilized)
    guard status == self.status, source == self.source else {
      throw DecodingError.dataCorruptedError(
        forKey: .status,
        in: container,
        debugDescription: "Captured screen constants do not match the tagged variant."
      )
    }
  }
}

public struct AgentWaitUnavailableScreen: Codable, Equatable, Sendable {
  public let status = "unavailable"
  public let requestedLines: Int
  public let source = "detection"
  public let waitedMilliseconds: Int

  enum CodingKeys: String, CodingKey {
    case status
    case requestedLines = "requested_lines"
    case source
    case waitedMilliseconds = "waited_ms"
  }

  public init(requestedLines: Int, waitedMilliseconds: Int) {
    self.requestedLines = requestedLines
    self.waitedMilliseconds = waitedMilliseconds
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let status = try container.decode(String.self, forKey: .status)
    self.requestedLines = try container.decode(Int.self, forKey: .requestedLines)
    let source = try container.decode(String.self, forKey: .source)
    self.waitedMilliseconds = try container.decode(Int.self, forKey: .waitedMilliseconds)
    guard status == self.status, source == self.source else {
      throw DecodingError.dataCorruptedError(
        forKey: .status,
        in: container,
        debugDescription: "Unavailable screen constants do not match the tagged variant."
      )
    }
  }
}

public struct AgentDispatchWaitPayload: Codable, Equatable, Sendable {
  public let mode = AgentWaitMode.dispatch
  public let waitedMilliseconds: Int
  public let target: TabTarget
  public let receipt: DispatchCompletedRecord
  public let signals: AgentSignalsPayload
  public let screen: AgentWaitScreenPayload?

  enum CodingKeys: String, CodingKey {
    case mode
    case waitedMilliseconds = "waited_ms"
    case target
    case receipt
    case signals
    case screen
  }

  public init(
    waitedMilliseconds: Int,
    target: TabTarget,
    receipt: DispatchCompletedRecord,
    signals: AgentSignalsPayload,
    screen: AgentWaitScreenPayload? = nil
  ) {
    self.waitedMilliseconds = waitedMilliseconds
    self.target = target
    self.receipt = receipt
    self.signals = signals
    self.screen = screen
  }
}

public struct AgentConditionWaitPayload: Codable, Equatable, Sendable {
  public let mode = AgentWaitMode.condition
  public let condition: AgentWaitCondition
  public let waitedMilliseconds: Int
  public let target: TabTarget
  public let observation: AgentWaitObservation
  public let signals: AgentSignalsPayload
  public let screen: AgentWaitScreenPayload?

  enum CodingKeys: String, CodingKey {
    case mode
    case condition
    case waitedMilliseconds = "waited_ms"
    case target
    case observation
    case signals
    case screen
  }

  public init(
    condition: AgentWaitCondition,
    waitedMilliseconds: Int,
    target: TabTarget,
    observation: AgentWaitObservation,
    signals: AgentSignalsPayload,
    screen: AgentWaitScreenPayload? = nil
  ) {
    self.condition = condition
    self.waitedMilliseconds = waitedMilliseconds
    self.target = target
    self.observation = observation
    self.signals = signals
    self.screen = screen
  }
}

public enum AgentWaitCommandPayload: Codable, Equatable, Sendable {
  case dispatch(AgentDispatchWaitPayload)
  case condition(AgentConditionWaitPayload)

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    let mode = try container.decode(AgentWaitMode.self, forKey: DynamicCodingKey("mode"))
    switch mode {
    case .dispatch:
      var keys: Set<String> = ["mode", "waited_ms", "target", "receipt", "signals"]
      if container.contains(DynamicCodingKey("screen")) { keys.insert("screen") }
      try requireExactKeys(container, keys, decoder: decoder)
      self = .dispatch(try AgentDispatchWaitPayload(from: decoder))
    case .condition:
      var keys: Set<String> = ["mode", "condition", "waited_ms", "target", "observation", "signals"]
      if container.contains(DynamicCodingKey("screen")) { keys.insert("screen") }
      try requireExactKeys(container, keys, decoder: decoder)
      self = .condition(try AgentConditionWaitPayload(from: decoder))
    }
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .dispatch(let payload): try payload.encode(to: encoder)
    case .condition(let payload): try payload.encode(to: encoder)
    }
  }
}

public struct AgentDispatchWaitErrorDetails: Codable, Equatable, Sendable {
  public let mode = AgentWaitMode.dispatch
  public let waitedMilliseconds: Int
  public let target: TabTarget
  public let record: DispatchRecordPayload
  public let observation: AgentWaitObservation?
  public let signals: AgentSignalsPayload?
  public let screen: AgentWaitScreenPayload?

  enum CodingKeys: String, CodingKey {
    case mode
    case waitedMilliseconds = "waited_ms"
    case target
    case record
    case observation
    case signals
    case screen
  }

  public init(
    waitedMilliseconds: Int,
    target: TabTarget,
    record: DispatchRecordPayload,
    observation: AgentWaitObservation? = nil,
    signals: AgentSignalsPayload? = nil,
    screen: AgentWaitScreenPayload? = nil
  ) {
    self.waitedMilliseconds = waitedMilliseconds
    self.target = target
    self.record = record
    self.observation = observation
    self.signals = signals
    self.screen = screen
  }
}

public struct AgentConditionWaitErrorDetails: Codable, Equatable, Sendable {
  public let mode = AgentWaitMode.condition
  public let condition: AgentWaitCondition
  public let waitedMilliseconds: Int
  public let target: TabTarget?
  public let observation: AgentWaitObservation?
  public let signals: AgentSignalsPayload?
  public let screen: AgentWaitScreenPayload?

  enum CodingKeys: String, CodingKey {
    case mode
    case condition
    case waitedMilliseconds = "waited_ms"
    case target
    case observation
    case signals
    case screen
  }

  public init(
    condition: AgentWaitCondition,
    waitedMilliseconds: Int,
    target: TabTarget? = nil,
    observation: AgentWaitObservation? = nil,
    signals: AgentSignalsPayload? = nil,
    screen: AgentWaitScreenPayload? = nil
  ) {
    self.condition = condition
    self.waitedMilliseconds = waitedMilliseconds
    self.target = target
    self.observation = observation
    self.signals = signals
    self.screen = screen
  }
}

public enum AgentWaitErrorDetails: Codable, Equatable, Sendable {
  case dispatch(AgentDispatchWaitErrorDetails)
  case condition(AgentConditionWaitErrorDetails)

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    let mode = try container.decode(AgentWaitMode.self, forKey: DynamicCodingKey("mode"))
    switch mode {
    case .dispatch:
      var keys: Set<String> = ["mode", "waited_ms", "target", "record"]
      if container.contains(DynamicCodingKey("observation")) { keys.insert("observation") }
      if container.contains(DynamicCodingKey("signals")) { keys.insert("signals") }
      if container.contains(DynamicCodingKey("screen")) { keys.insert("screen") }
      try requireExactKeys(container, keys, decoder: decoder)
      self = .dispatch(try AgentDispatchWaitErrorDetails(from: decoder))
    case .condition:
      var keys: Set<String> = ["mode", "condition", "waited_ms"]
      for key in ["target", "observation", "signals", "screen"]
      where container.contains(DynamicCodingKey(key)) {
        keys.insert(key)
      }
      try requireExactKeys(container, keys, decoder: decoder)
      self = .condition(try AgentConditionWaitErrorDetails(from: decoder))
    }
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .dispatch(let details): try details.encode(to: encoder)
    case .condition(let details): try details.encode(to: encoder)
    }
  }
}

private func requireExactKeys(
  _ container: KeyedDecodingContainer<DynamicCodingKey>,
  _ expected: Set<String>,
  decoder: Decoder
) throws {
  guard Set(container.allKeys.map(\.stringValue)) == expected else {
    throw DecodingError.dataCorrupted(
      .init(codingPath: decoder.codingPath, debugDescription: "Fields do not match the tagged variant.")
    )
  }
}

private struct DynamicCodingKey: CodingKey, Hashable {
  let stringValue: String
  let intValue: Int? = nil

  init(_ stringValue: String) {
    self.stringValue = stringValue
  }

  init?(stringValue: String) {
    self.init(stringValue)
  }

  init?(intValue: Int) {
    return nil
  }
}
