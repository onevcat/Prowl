import Foundation

/// One row of the chat: events merged into what a person reads (docs-ai 088). Tool starts
/// and ends share a card, prompts carry their resolution, queued messages disappear once
/// the agent takes them.
nonisolated enum MirrorConversationItem: Identifiable, Equatable, Sendable {
  typealias Event = MirrorConversationEvent

  case user(id: UInt64, text: MirrorBoundedText, origin: Event.MessageOrigin?, images: Int?, at: Date?)
  case queued(id: UInt64, text: String)
  case assistant(id: UInt64, text: MirrorBoundedText, phase: Event.MessagePhase?, at: Date?)
  case reasoning(id: UInt64, durationMs: Int?, summary: MirrorBoundedText?)
  case tool(id: UInt64, start: Event.ToolStart, end: Event.ToolEnd?, startedAt: Date?, endedAt: Date?)
  case prompt(id: UInt64, prompt: Event.Prompt, resolved: Event.Prompt?, at: Date?)
  case attention(id: UInt64, status: Event.Status, at: Date?)
  case session(id: UInt64, kind: Event.Kind, session: Event.Session?, at: Date?)
  case compaction(id: UInt64, at: Date?)
  case subagent(id: UInt64, kind: Event.Kind, agent: Event.Subagent)
  case notice(id: UInt64, notice: Event.Notice, at: Date?)

  var id: UInt64 {
    switch self {
    case .user(let id, _, _, _, _), .queued(let id, _), .assistant(let id, _, _, _), .reasoning(let id, _, _),
      .tool(let id, _, _, _, _), .prompt(let id, _, _, _), .attention(let id, _, _), .session(let id, _, _, _),
      .compaction(let id, _), .subagent(let id, _, _), .notice(let id, _, _):
      id
    }
  }
}

/// A pane's conversation as received over `conversation-v1`: events keyed by sequence, the
/// current session and agent status, and the items the chat renders.
nonisolated struct MirrorConversationStore: Equatable, Sendable {
  static let maximumEvents = 2000

  private(set) var events: [MirrorConversationEvent] = []
  private(set) var latestSequence: UInt64 = 0
  private(set) var session: MirrorConversationEvent.Session?
  private(set) var status: MirrorConversationEvent.Status?
  private(set) var statusAt: Date?
  /// Events before `events.first` were dropped by the Host or trimmed here.
  private(set) var gap = false
  private(set) var items: [MirrorConversationItem] = []

  var agentState: MirrorConversationEvent.AgentState? { status?.state }
  var isEmpty: Bool { events.isEmpty }

  /// A snapshot that did not resume replaces everything the store holds.
  mutating func apply(
    snapshot: [MirrorConversationEvent], gap: Bool, sequence: UInt64,
    session: MirrorConversationEvent.Session?, resumed: Bool
  ) {
    if !resumed { reset() }
    if gap { self.gap = true }
    append(snapshot, sequence: sequence)
    if let session { self.session = session }
  }

  mutating func apply(events: [MirrorConversationEvent], sequence: UInt64) {
    append(events, sequence: sequence)
  }

  mutating func reset() {
    events.removeAll()
    latestSequence = 0
    session = nil
    status = nil
    statusAt = nil
    gap = false
    items.removeAll()
  }

  private mutating func append(_ newEvents: [MirrorConversationEvent], sequence: UInt64) {
    let fresh = newEvents.filter { $0.sequence > latestSequence }
    for event in fresh {
      events.append(event)
      latestSequence = event.sequence
      track(event)
    }
    latestSequence = max(latestSequence, sequence)
    if events.count > Self.maximumEvents {
      events.removeFirst(events.count - Self.maximumEvents)
      gap = true
    }
    if !fresh.isEmpty { rebuildItems() }
  }

  private mutating func track(_ event: MirrorConversationEvent) {
    switch (event.kind, event.payload) {
    case (.sessionStarted, .session(let started)):
      session = started
    case (.sessionUpdated, .session(let update)):
      var merged = session ?? .init()
      if let id = update.id { merged.id = id }
      if let cwd = update.cwd { merged.cwd = cwd }
      if let model = update.model { merged.model = model }
      if let title = update.title { merged.title = title }
      if let version = update.version { merged.version = version }
      if let cost = update.costUSD { merged.costUSD = cost }
      session = merged
    case (.sessionChanged, _), (.sessionPending, _), (.sessionEnded, _):
      session = nil
    case (.agentStatus, .status(let status)):
      self.status = status
      statusAt = event.timestamp
    default:
      break
    }
  }

  // MARK: - Items

  private mutating func rebuildItems() {
    var result: [MirrorConversationItem] = []
    var toolIndex: [String: Int] = [:]
    var promptIndex: [String: Int] = [:]
    for event in events {
      switch (event.kind, event.payload) {
      case (.userMessage, .message(let message)):
        result.append(
          .user(id: event.sequence, text: message.text, origin: message.origin, images: message.images, at: event.timestamp))
      case (.userQueued, .message(let message)):
        result.append(.queued(id: event.sequence, text: message.text.text))
      case (.userUnqueued, .message(let message)):
        if let index = result.lastIndex(where: { item in
          if case .queued(_, let text) = item { return text == message.text.text }
          return false
        }) {
          result.remove(at: index)
        }
      case (.assistantMessage, .message(let message)):
        result.append(.assistant(id: event.sequence, text: message.text, phase: message.phase, at: event.timestamp))
      case (.assistantReasoning, .reasoning(let reasoning)):
        guard (reasoning.durationMs ?? 0) >= 1000 || reasoning.summary != nil else { continue }
        result.append(.reasoning(id: event.sequence, durationMs: reasoning.durationMs, summary: reasoning.summary))
      case (.toolStarted, .toolStart(let start)):
        toolIndex[start.id] = result.count
        result.append(.tool(id: event.sequence, start: start, end: nil, startedAt: event.timestamp, endedAt: nil))
      case (.toolCompleted, .toolEnd(let end)):
        if let index = toolIndex[end.id], case .tool(let id, let start, _, let startedAt, _) = result[index] {
          result[index] = .tool(id: id, start: start, end: end, startedAt: startedAt, endedAt: event.timestamp)
        } else {
          let start = MirrorConversationEvent.ToolStart(
            id: end.id, name: end.name ?? "Tool", kind: .other, title: end.name ?? "Tool")
          result.append(.tool(id: event.sequence, start: start, end: end, startedAt: nil, endedAt: event.timestamp))
        }
      case (.promptOpened, .prompt(let prompt)):
        promptIndex[prompt.id] = result.count
        result.append(.prompt(id: event.sequence, prompt: prompt, resolved: nil, at: event.timestamp))
      case (.promptResolved, .prompt(let resolution)):
        if let index = promptIndex[resolution.id], case .prompt(let id, let prompt, _, let at) = result[index] {
          result[index] = .prompt(id: id, prompt: prompt, resolved: resolution, at: at)
        }
      case (.agentStatus, .status(let status)):
        if status.state == .blocked {
          result.append(.attention(id: event.sequence, status: status, at: event.timestamp))
        }
      case (.sessionStarted, .session(let started)), (.sessionChanged, .session(let started)),
        (.sessionPending, .session(let started)), (.sessionEnded, .session(let started)):
        result.append(.session(id: event.sequence, kind: event.kind, session: started, at: event.timestamp))
      case (.contextCompacted, _):
        result.append(.compaction(id: event.sequence, at: event.timestamp))
      case (.subagentStarted, .subagent(let agent)), (.subagentCompleted, .subagent(let agent)):
        result.append(.subagent(id: event.sequence, kind: event.kind, agent: agent))
      case (.notice, .notice(let notice)):
        guard notice.level != .debug else { continue }
        result.append(.notice(id: event.sequence, notice: notice, at: event.timestamp))
      default:
        break
      }
    }
    items = result
  }
}
