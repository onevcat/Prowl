import Foundation

/// Claude Code's `~/.claude/projects/<cwd>/<session>.jsonl` (docs-ai 087). Records land as
/// they happen: a `tool_use` block when the tool starts, its `tool_result` when it ends, a
/// `system` `turn_duration` when the turn closes, `queue-operation` for messages typed
/// while the agent works.
nonisolated struct ClaudeConversationAdapter: MirrorConversationAdapter {
  private typealias Event = MirrorConversationEvent
  private typealias Value = MirrorConversationRecordValue

  let agent = DetectedAgent.claude
  private var announcedSessionID: String?
  private var lastTitle: String?
  private var pendingTools: [String: (start: Event.ToolStart, at: Date?)] = [:]

  private static let toolKinds: [String: Event.ToolKind] = [
    "Bash": .shell, "Read": .read, "Write": .edit, "Edit": .edit, "MultiEdit": .edit, "NotebookEdit": .edit,
    "Grep": .search, "Glob": .search, "WebFetch": .web, "WebSearch": .web, "Agent": .agent, "Task": .agent,
    "AskUserQuestion": .question, "ExitPlanMode": .plan, "EnterPlanMode": .plan, "Skill": .skill,
  ]

  mutating func events(for record: MirrorConversationRecord) -> [MirrorConversationEvent] {
    let type = Value.string(record, "type")
    let timestamp = Value.timestamp(record)
    var events: [Event] = []
    if let type, ["user", "assistant", "system"].contains(type), let id = Value.string(record, "sessionId"),
      id != announcedSessionID
    {
      announcedSessionID = id
      let session = Event.Session(id: id, cwd: Value.string(record, "cwd"), version: Value.string(record, "version"))
      events.append(Event(.sessionStarted, .session(session), at: timestamp, source: .transcript))
    }
    switch type {
    case "user": events += userEvents(record, at: timestamp)
    case "assistant": events += assistantEvents(record, at: timestamp)
    case "system": events += Self.systemEvents(record, at: timestamp)
    case "queue-operation": events += Self.queueEvents(record, at: timestamp)
    case "ai-title": events += titleEvents(record)
    case "cost-state":
      if let cost = Value.double(record, "totalCostUSD") {
        events.append(Event(.sessionUpdated, .session(.init(costUSD: cost)), at: nil, source: .transcript))
      }
    default: break
    }
    return events
  }

  // MARK: - User records

  private mutating func userEvents(_ record: MirrorConversationRecord, at timestamp: Date?) -> [Event] {
    guard Value.bool(record, "isMeta") != true, let message = Value.object(record, "message") else { return [] }
    let origin = Self.origin(of: record)
    var events: [Event] = []
    if let text = message["content"] as? String {
      events.append(Self.turnStart(record, origin: origin, at: timestamp))
      events.append(
        Event(.userMessage, .message(.init(text: .init(text), origin: origin)), at: timestamp, source: .transcript))
    } else if let blocks = Value.objects(message, "content") {
      events += blockEvents(blocks, record: record, origin: origin, at: timestamp)
    }
    if let decision = Value.object(record, "permissionDecision"), let decidedBy = Value.string(decision, "source"),
      decidedBy != "config", let toolID = Self.firstToolResultID(message)
    {
      let prompt = Event.Prompt(
        id: toolID, kind: .permission, freeform: false, outcome: Self.outcome(of: decision), decidedBy: decidedBy)
      events.append(Event(.promptResolved, .prompt(prompt), at: timestamp, source: .transcript))
    }
    return events
  }

  private mutating func blockEvents(
    _ blocks: [MirrorConversationRecord], record: MirrorConversationRecord, origin: Event.MessageOrigin,
    at timestamp: Date?
  ) -> [Event] {
    var events: [Event] = []
    var texts: [String] = []
    var images = 0
    var sawToolResult = false
    for block in blocks {
      switch Value.string(block, "type") {
      case "text":
        if let text = Value.string(block, "text") { texts.append(text) }
      case "image":
        images += 1
      case "tool_result":
        sawToolResult = true
        events.append(toolEnd(block, record: record, at: timestamp))
      default:
        break
      }
    }
    guard !sawToolResult, !texts.isEmpty || images > 0 else { return events }
    let message = Event.Message(
      text: .init(texts.joined(separator: "\n")), origin: origin, images: images > 0 ? images : nil)
    return [
      Self.turnStart(record, origin: origin, at: timestamp),
      Event(.userMessage, .message(message), at: timestamp, source: .transcript),
    ]
  }

  private mutating func toolEnd(
    _ block: MirrorConversationRecord, record: MirrorConversationRecord, at timestamp: Date?
  ) -> Event {
    let id = Value.string(block, "tool_use_id") ?? ""
    let pending = pendingTools.removeValue(forKey: id)
    let result = Value.object(record, "toolUseResult")
    let interrupted = result.flatMap { Value.bool($0, "interrupted") } ?? false
    let status: Event.ToolStatus =
      Value.bool(block, "is_error") == true ? .error : (interrupted ? .interrupted : .succeeded)
    let duration = pending?.at.flatMap { start in timestamp.map { Int($0.timeIntervalSince(start) * 1000) } }
    let end = Event.ToolEnd(
      id: id, name: pending?.start.name, status: status, output: Value.blockText(block["content"]).map { .init($0) },
      durationMs: duration, isImage: result.flatMap { Value.bool($0, "isImage") })
    return Event(.toolCompleted, .toolEnd(end), at: timestamp, source: .transcript)
  }

  // MARK: - Assistant records

  private mutating func assistantEvents(_ record: MirrorConversationRecord, at timestamp: Date?) -> [Event] {
    guard let message = Value.object(record, "message"), let blocks = Value.objects(message, "content") else {
      return []
    }
    let model = Value.string(message, "model")
    var events: [Event] = []
    for block in blocks {
      switch Value.string(block, "type") {
      case "text":
        if let text = Value.string(block, "text"), !text.isEmpty {
          events.append(
            Event(
              .assistantMessage, .message(.init(text: .init(text), model: model)), at: timestamp, source: .transcript))
        }
      case "thinking":
        let reasoning = Event.Reasoning(durationMs: Value.int(record, "thinkingDurationMs"))
        events.append(Event(.assistantReasoning, .reasoning(reasoning), at: timestamp, source: .transcript))
      case "tool_use":
        events += toolStartEvents(block, at: timestamp)
      default:
        break
      }
    }
    return events
  }

  private mutating func toolStartEvents(_ block: MirrorConversationRecord, at timestamp: Date?) -> [Event] {
    guard let id = Value.string(block, "id"), let name = Value.string(block, "name") else { return [] }
    let input = Value.object(block, "input") ?? [:]
    let kind = Self.toolKinds[name] ?? (name.hasPrefix("mcp__") ? .mcp : .other)
    let start = Event.ToolStart(
      id: id, name: name, kind: kind, title: Self.toolTitle(name, input: input),
      command: Value.string(input, "command"),
      path: Value.string(input, "file_path"), background: Value.bool(input, "run_in_background"))
    pendingTools[id] = (start, timestamp)
    var events = [Event(.toolStarted, .toolStart(start), at: timestamp, source: .transcript)]
    if let prompt = Self.prompt(for: name, id: id, input: input) {
      events.append(Event(.promptOpened, .prompt(prompt), at: timestamp, source: .transcript))
    }
    return events
  }

  private static func toolTitle(_ name: String, input: MirrorConversationRecord) -> String {
    let keys =
      name == "Bash"
      ? ["description", "command"]
      : ["file_path", "path", "pattern", "url", "query", "prompt", "description", "skill", "name"]
    for key in keys {
      if let value = Value.string(input, key), !value.isEmpty { return Value.title(value) }
    }
    return ""
  }

  /// AskUserQuestion carries its questions in the tool input, so the prompt is complete before
  /// the dialog opens. ExitPlanMode asks the person to accept the plan.
  private static func prompt(for name: String, id: String, input: MirrorConversationRecord) -> Event.Prompt? {
    switch name {
    case "AskUserQuestion":
      let questions = (Value.objects(input, "questions") ?? []).enumerated().map { index, question in
        let options = (Value.objects(question, "options") ?? []).enumerated().map { optionIndex, option in
          Event.Choice(
            id: String(optionIndex), label: Value.string(option, "label") ?? "",
            description: Value.string(option, "description").map { Value.title($0) })
        }
        return Event.Question(
          id: String(index), header: Value.string(question, "header"),
          question: Value.string(question, "question") ?? "",
          multiSelect: Value.bool(question, "multiSelect") ?? false, options: options)
      }
      return Event.Prompt(id: id, kind: .question, questions: questions, freeform: true)
    case "ExitPlanMode":
      let choices = [
        Event.Choice(id: "approve", label: "Approve plan"), Event.Choice(id: "reject", label: "Keep planning"),
      ]
      return Event.Prompt(id: id, kind: .planApproval, choices: choices, freeform: true)
    default:
      return nil
    }
  }

  // MARK: - System, queue, title

  private static func systemEvents(_ record: MirrorConversationRecord, at timestamp: Date?) -> [Event] {
    switch Value.string(record, "subtype") {
    case "turn_duration":
      let turn = Event.Turn(status: .completed, durationMs: Value.int(record, "durationMs"))
      return [Event(.turnCompleted, .turn(turn), at: timestamp, source: .transcript)]
    case "compact_boundary":
      return [Event(.contextCompacted, .none, at: timestamp, source: .transcript)]
    case "stop_hook_summary":
      guard let errors = record["hookErrors"] as? [Any], !errors.isEmpty else { return [] }
      let notice = Event.Notice(level: .warning, text: "\(errors.count) hook error(s)", subtype: "stop_hook_summary")
      return [Event(.notice, .notice(notice), at: timestamp, source: .transcript)]
    case "informational", "local_command", "away_summary":
      guard let content = Value.string(record, "content"), !content.isEmpty else { return [] }
      let level: Event.NoticeLevel = Value.string(record, "level") == "notice" ? .warning : .info
      let notice = Event.Notice(
        level: level, text: Value.title(content, limit: 200), subtype: Value.string(record, "subtype"))
      return [Event(.notice, .notice(notice), at: timestamp, source: .transcript)]
    default:
      return []
    }
  }

  private static func queueEvents(_ record: MirrorConversationRecord, at timestamp: Date?) -> [Event] {
    guard let operation = Value.string(record, "operation"), let content = Value.string(record, "content") else {
      return []
    }
    let kind: Event.Kind = operation == "enqueue" ? .userQueued : .userUnqueued
    let message = Event.Message(
      text: .init(content, limit: 512), origin: .queued, reason: Value.string(record, "reason"))
    return [Event(kind, .message(message), at: timestamp, source: .transcript)]
  }

  private mutating func titleEvents(_ record: MirrorConversationRecord) -> [Event] {
    guard let title = Value.string(record, "aiTitle"), !title.isEmpty, title != lastTitle else { return [] }
    lastTitle = title
    return [Event(.sessionUpdated, .session(.init(title: title)), at: nil, source: .transcript)]
  }

  // MARK: - Helpers

  private static func turnStart(
    _ record: MirrorConversationRecord, origin: Event.MessageOrigin, at timestamp: Date?
  ) -> Event {
    Event(
      .turnStarted, .turn(.init(id: Value.string(record, "promptId"), origin: origin)), at: timestamp,
      source: .transcript)
  }

  private static func origin(of record: MirrorConversationRecord) -> Event.MessageOrigin {
    let raw = Value.object(record, "origin").flatMap { Value.string($0, "kind") } ?? Value.string(record, "turnOrigin")
    switch raw {
    case "human": return .human
    case "queued": return .queued
    case "automation", "dispatch": return .automation
    case "system": return .system
    default: return .other
    }
  }

  private static func firstToolResultID(_ message: MirrorConversationRecord) -> String? {
    Value.objects(message, "content")?
      .first { Value.string($0, "type") == "tool_result" }
      .flatMap { Value.string($0, "tool_use_id") }
  }

  private static func outcome(of decision: MirrorConversationRecord) -> Event.PromptOutcome {
    switch Value.string(decision, "decision") {
    case "accept": .allowed
    case "reject": .denied
    default: .unknown
    }
  }
}
