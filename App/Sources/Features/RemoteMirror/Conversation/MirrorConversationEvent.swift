import Foundation

/// One bounded text value on the conversation wire. The Host cuts long text at a
/// character boundary and says so, so a client never guesses whether output was complete.
nonisolated struct MirrorBoundedText: Codable, Equatable, Sendable {
  static let defaultLimit = 4 * 1024

  let text: String
  let truncated: Bool
  /// UTF-8 byte count of the complete text; present only when truncated.
  let totalBytes: Int?

  init(_ text: String, limit: Int = MirrorBoundedText.defaultLimit) {
    let total = text.utf8.count
    guard total > limit else {
      self.text = text
      truncated = false
      totalBytes = nil
      return
    }
    var end = text.startIndex
    var bytes = 0
    while end < text.endIndex {
      let next = text.index(after: end)
      let count = text.utf8.distance(from: end, to: next)
      if bytes + count > limit { break }
      bytes += count
      end = next
    }
    self.text = String(text[..<end])
    truncated = true
    totalBytes = total
  }
}

/// A `conversation-v1` event (docs-ai 087): one thing an agent pane did, in a shape shared
/// by every supported agent. `data` holds the payload family that `kind` selects; a client
/// ignores kinds it does not know.
nonisolated struct MirrorConversationEvent: Codable, Equatable, Sendable {
  enum Kind: String, Codable, CaseIterable, Sendable {
    case sessionStarted = "session.started"
    case sessionUpdated = "session.updated"
    case sessionChanged = "session.changed"
    case sessionPending = "session.pending"
    case sessionEnded = "session.ended"
    case turnStarted = "turn.started"
    case turnCompleted = "turn.completed"
    case userMessage = "user.message"
    case userQueued = "user.queued"
    case userUnqueued = "user.unqueued"
    case assistantMessage = "assistant.message"
    case assistantReasoning = "assistant.reasoning"
    case toolStarted = "tool.started"
    case toolCompleted = "tool.completed"
    case agentStatus = "agent.status"
    case promptOpened = "prompt.opened"
    case promptResolved = "prompt.resolved"
    case contextCompacted = "context.compacted"
    case subagentStarted = "subagent.started"
    case subagentCompleted = "subagent.completed"
    case notice

    var family: PayloadFamily {
      switch self {
      case .sessionStarted, .sessionUpdated, .sessionChanged, .sessionPending, .sessionEnded: .session
      case .turnStarted, .turnCompleted: .turn
      case .userMessage, .userQueued, .userUnqueued, .assistantMessage: .message
      case .assistantReasoning: .reasoning
      case .toolStarted: .toolStart
      case .toolCompleted: .toolEnd
      case .agentStatus: .status
      case .promptOpened, .promptResolved: .prompt
      case .subagentStarted, .subagentCompleted: .subagent
      case .notice: .notice
      case .contextCompacted: .none
      }
    }
  }

  /// Which Host input produced the event.
  enum Source: String, Codable, Sendable {
    case transcript
    case hook
    case osc
    case screen
    case host
  }

  enum PayloadFamily: Equatable, Sendable {
    case session, turn, message, reasoning, toolStart, toolEnd, status, prompt, subagent, notice, none
  }

  enum Payload: Equatable, Sendable {
    case session(Session)
    case turn(Turn)
    case message(Message)
    case reasoning(Reasoning)
    case toolStart(ToolStart)
    case toolEnd(ToolEnd)
    case status(Status)
    case prompt(Prompt)
    case subagent(Subagent)
    case notice(Notice)
    case none

    var family: PayloadFamily {
      switch self {
      case .session: .session
      case .turn: .turn
      case .message: .message
      case .reasoning: .reasoning
      case .toolStart: .toolStart
      case .toolEnd: .toolEnd
      case .status: .status
      case .prompt: .prompt
      case .subagent: .subagent
      case .notice: .notice
      case .none: .none
      }
    }
  }

  /// Assigned by `MirrorConversationLog`; 0 before an event is appended.
  var sequence: UInt64
  var timestamp: Date?
  let kind: Kind
  let source: Source
  let payload: Payload

  init(_ kind: Kind, _ payload: Payload, at timestamp: Date?, source: Source, sequence: UInt64 = 0) {
    assert(kind.family == payload.family, "\(kind) cannot carry \(payload.family)")
    self.sequence = sequence
    self.timestamp = timestamp
    self.kind = kind
    self.source = source
    self.payload = payload
  }

  /// True when `payload` is the family `kind` selects; decoding enforces it, adapters assert it.
  var isConsistent: Bool { kind.family == payload.family }

  private enum CodingKeys: String, CodingKey {
    case sequence = "seq"
    case timestamp = "ts"
    case kind
    case source
    case data
  }

  private struct EmptyPayload: Codable {}

  private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  /// Timestamps carry whole milliseconds, so a parse → format round trip is exact; the
  /// system style truncates fractions and turned `.754` into `.753`.
  static func parseTimestamp(_ string: String) -> Date? {
    let parsed = (try? fractionalStyle.parse(string)) ?? (try? Date.ISO8601FormatStyle().parse(string))
    return parsed.map(roundedToMilliseconds)
  }

  static func formatTimestamp(_ date: Date) -> String {
    let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
    let whole = Date(timeIntervalSince1970: TimeInterval(milliseconds.quotientAndRemainder(dividingBy: 1000).quotient))
    let fraction = Int(milliseconds.quotientAndRemainder(dividingBy: 1000).remainder)
    return String(Date.ISO8601FormatStyle().format(whole).dropLast()) + String(format: ".%03dZ", abs(fraction))
  }

  static func roundedToMilliseconds(_ date: Date) -> Date {
    Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sequence = try container.decodeIfPresent(UInt64.self, forKey: .sequence) ?? 0
    if let raw = try container.decodeIfPresent(String.self, forKey: .timestamp) {
      guard let date = Self.parseTimestamp(raw) else {
        throw DecodingError.dataCorruptedError(forKey: .timestamp, in: container, debugDescription: "bad timestamp")
      }
      timestamp = date
    } else {
      timestamp = nil
    }
    kind = try container.decode(Kind.self, forKey: .kind)
    source = try container.decode(Source.self, forKey: .source)
    switch kind.family {
    case .session: payload = .session(try container.decode(Session.self, forKey: .data))
    case .turn: payload = .turn(try container.decode(Turn.self, forKey: .data))
    case .message: payload = .message(try container.decode(Message.self, forKey: .data))
    case .reasoning: payload = .reasoning(try container.decode(Reasoning.self, forKey: .data))
    case .toolStart: payload = .toolStart(try container.decode(ToolStart.self, forKey: .data))
    case .toolEnd: payload = .toolEnd(try container.decode(ToolEnd.self, forKey: .data))
    case .status: payload = .status(try container.decode(Status.self, forKey: .data))
    case .prompt: payload = .prompt(try container.decode(Prompt.self, forKey: .data))
    case .subagent: payload = .subagent(try container.decode(Subagent.self, forKey: .data))
    case .notice: payload = .notice(try container.decode(Notice.self, forKey: .data))
    case .none:
      _ = try container.decodeIfPresent(EmptyPayload.self, forKey: .data)
      payload = .none
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sequence, forKey: .sequence)
    if let timestamp {
      try container.encode(Self.formatTimestamp(timestamp), forKey: .timestamp)
    }
    try container.encode(kind, forKey: .kind)
    try container.encode(source, forKey: .source)
    switch payload {
    case .session(let value): try container.encode(value, forKey: .data)
    case .turn(let value): try container.encode(value, forKey: .data)
    case .message(let value): try container.encode(value, forKey: .data)
    case .reasoning(let value): try container.encode(value, forKey: .data)
    case .toolStart(let value): try container.encode(value, forKey: .data)
    case .toolEnd(let value): try container.encode(value, forKey: .data)
    case .status(let value): try container.encode(value, forKey: .data)
    case .prompt(let value): try container.encode(value, forKey: .data)
    case .subagent(let value): try container.encode(value, forKey: .data)
    case .notice(let value): try container.encode(value, forKey: .data)
    case .none: try container.encode(EmptyPayload(), forKey: .data)
    }
  }
}
