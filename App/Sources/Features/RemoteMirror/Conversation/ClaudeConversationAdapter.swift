import Foundation

/// Claude Code's `~/.claude/projects/<cwd>/<session>.jsonl` (docs-ai 087). Records land as
/// they happen: a `tool_use` block when the tool starts, its `tool_result` when it ends, a
/// `system` `turn_duration` when the turn closes, `queue-operation` for messages typed
/// while the agent works. Generated `user` records (compaction summaries, slash-command
/// echoes, meta prompts) are not human turns.
nonisolated struct ClaudeConversationAdapter: MirrorConversationAdapter {
  private typealias Event = MirrorConversationEvent
  private typealias Value = MirrorConversationRecordValue

  private struct PendingTool {
    let start: Event.ToolStart
    let startedAt: Date?
    let prompt: Event.PromptKind?
  }

  let agent = DetectedAgent.claude
  private var announcedSessionID: String?
  private var lastTitle: String?
  private var pendingTools: [String: PendingTool] = [:]
  /// Messages typed while the agent worked, oldest first; `dequeue` records carry no text.
  private var queued: [String] = []

  private static let toolKinds: [String: Event.ToolKind] = [
    "Bash": .shell, "Read": .read, "Write": .edit, "Edit": .edit, "MultiEdit": .edit, "NotebookEdit": .edit,
    "Grep": .search, "Glob": .search, "WebFetch": .web, "WebSearch": .web, "Agent": .agent, "Task": .agent,
    "AskUserQuestion": .question, "ExitPlanMode": .plan, "EnterPlanMode": .plan, "Skill": .skill,
  ]

  mutating func bootstrap(_ record: MirrorConversationRecord) -> [MirrorConversationEvent] {
    announce(record, at: Value.timestamp(record))
  }

  mutating func events(for record: MirrorConversationRecord) -> [MirrorConversationEvent] {
    let timestamp = Value.timestamp(record)
    var events = announce(record, at: timestamp)
    switch Value.string(record, "type") {
    case "user": events += userEvents(record, at: timestamp)
    case "assistant": events += assistantEvents(record, at: timestamp)
    case "system": events += systemEvents(record, at: timestamp)
    case "queue-operation": events += queueEvents(record, at: timestamp)
    case "ai-title": events += titleEvents(record)
    case "cost-state":
      if let cost = Value.double(record, "totalCostUSD") {
        events.append(Event(.sessionUpdated, .session(.init(costUSD: cost)), at: nil, source: .transcript))
      }
    default: break
    }
    return events
  }

  private mutating func announce(_ record: MirrorConversationRecord, at timestamp: Date?) -> [Event] {
    guard let type = Value.string(record, "type"), ["user", "assistant", "system"].contains(type),
      let id = Value.string(record, "sessionId"), id != announcedSessionID
    else { return [] }
    announcedSessionID = id
    let session = Event.Session(id: id, cwd: Value.string(record, "cwd"), version: Value.string(record, "version"))
    return [Event(.sessionStarted, .session(session), at: timestamp, source: .transcript)]
  }

  // MARK: - User records

  private mutating func userEvents(_ record: MirrorConversationRecord, at timestamp: Date?) -> [Event] {
    guard Value.bool(record, "isMeta") != true, Value.bool(record, "isCompactSummary") != true,
      Value.bool(record, "isVisibleInTranscriptOnly") != true, let message = Value.object(record, "message")
    else { return [] }
    let origin = Self.origin(of: record)
    if let text = message["content"] as? String {
      return Self.humanMessage(text, record: record, origin: origin, at: timestamp)
    }
    guard let blocks = Value.objects(message, "content") else { return [] }
    var events: [Event] = []
    var texts: [String] = []
    var sawToolResult = false
    for block in blocks {
      switch Value.string(block, "type") {
      case "text":
        if let text = Value.string(block, "text") { texts.append(text) }
      case "tool_result":
        sawToolResult = true
        events += toolEnd(block, record: record, at: timestamp)
      default:
        break
      }
    }
    let images = Value.imageCount(blocks)
    guard !sawToolResult, !texts.isEmpty || images > 0 else { return events }
    return Self.humanMessage(
      texts.joined(separator: "\n"), record: record, origin: origin, images: images, at: timestamp)
  }

  /// Slash commands echo as user records wrapped in `<command-name>` / `<local-command-stdout>`.
  private static func humanMessage(
    _ text: String, record: MirrorConversationRecord, origin: Event.MessageOrigin, images: Int = 0, at timestamp: Date?
  ) -> [Event] {
    if text.hasPrefix("<local-command-stdout>") { return [] }
    if text.hasPrefix("<command-name>") {
      guard let command = tag("command-name", in: text), !command.isEmpty else { return [] }
      let notice = Event.Notice(level: .info, text: Value.title(command, limit: 200), subtype: "command")
      return [Event(.notice, .notice(notice), at: timestamp, source: .transcript)]
    }
    let message = Event.Message(text: .init(text), origin: origin, images: images > 0 ? images : nil)
    let turn = Event.Turn(id: Value.string(record, "promptId"), origin: origin)
    return [
      Event(.turnStarted, .turn(turn), at: timestamp, source: .transcript),
      Event(.userMessage, .message(message), at: timestamp, source: .transcript),
    ]
  }

  private mutating func toolEnd(
    _ block: MirrorConversationRecord, record: MirrorConversationRecord, at timestamp: Date?
  ) -> [Event] {
    let id = Value.string(block, "tool_use_id") ?? ""
    let pending = pendingTools.removeValue(forKey: id)
    let result = Value.object(record, "toolUseResult")
    let interrupted = result.flatMap { Value.bool($0, "interrupted") } ?? false
    let status: Event.ToolStatus =
      Value.bool(block, "is_error") == true ? .error : (interrupted ? .interrupted : .succeeded)
    let duration = pending?.startedAt.flatMap { start in
      timestamp.map { Int(($0.timeIntervalSince(start) * 1000).rounded()) }
    }
    let end = Event.ToolEnd(
      id: id, name: pending?.start.name, status: status, output: Value.blockText(block["content"]).map { .init($0) },
      diff: pending?.start.kind == .edit
        ? Self.editDiff(result).map { .init($0, limit: MirrorBoundedText.diffLimit) } : nil,
      durationMs: duration, isImage: result.flatMap { Value.bool($0, "isImage") })
    var events = [Event(.toolCompleted, .toolEnd(end), at: timestamp, source: .transcript)]
    if let kind = pending?.prompt {
      // The prompt the adapter opened is answered by the tool's completion, whatever the
      // permission bookkeeping says about running the tool.
      let prompt = Event.Prompt(
        id: id, kind: kind, freeform: true, outcome: status == .succeeded ? .answered : .dismissed)
      events.append(Event(.promptResolved, .prompt(prompt), at: timestamp, source: .transcript))
    } else if let decision = Value.object(record, "permissionDecision"),
      let source = Value.string(decision, "source"), source.hasPrefix("user")
    {
      let prompt = Event.Prompt(
        id: id, kind: .permission, freeform: false, outcome: Self.outcome(of: decision), decidedBy: source)
      events.append(Event(.promptResolved, .prompt(prompt), at: timestamp, source: .transcript))
    }
    return events
  }

  /// `structuredPatch` hunks for edits; the written content as added lines for a new file.
  private static func editDiff(_ result: MirrorConversationRecord?) -> String? {
    guard let result else { return nil }
    if let hunks = Value.objects(result, "structuredPatch"), !hunks.isEmpty {
      return hunks.map { hunk -> String in
        let header =
          "@@ -\(Value.int(hunk, "oldStart") ?? 0),\(Value.int(hunk, "oldLines") ?? 0) "
          + "+\(Value.int(hunk, "newStart") ?? 0),\(Value.int(hunk, "newLines") ?? 0) @@"
        return ([header] + ((hunk["lines"] as? [String]) ?? [])).joined(separator: "\n")
      }.joined(separator: "\n")
    }
    guard Value.string(result, "type") == "create", let content = Value.string(result, "content") else { return nil }
    return content.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
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
        // Claude Code shows a thinking block in the pane like a reply only when its signature
        // marks it as narration; other thinking stays hidden there, so only its duration goes.
        let thought = Value.string(block, "thinking")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = ClaudeThinkingSignature.isNarration(Value.string(block, "signature"))
        let reasoning = Event.Reasoning(
          durationMs: Value.int(record, "thinkingDurationMs"),
          summary: thought.flatMap { !shown || $0.isEmpty || $0 == "…" ? nil : MirrorBoundedText($0) })
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
    let prompt = Self.prompt(for: name, id: id, input: input)
    pendingTools[id] = PendingTool(start: start, startedAt: timestamp, prompt: prompt?.kind)
    var events = [Event(.toolStarted, .toolStart(start), at: timestamp, source: .transcript)]
    if let prompt { events.append(Event(.promptOpened, .prompt(prompt), at: timestamp, source: .transcript)) }
    return events
  }

  private static func toolTitle(_ name: String, input: MirrorConversationRecord) -> String {
    let keys =
      name == "Bash"
      ? ["description", "command"]
      : ["description", "file_path", "pattern", "path", "url", "query", "skill", "name", "prompt"]
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

  private mutating func systemEvents(_ record: MirrorConversationRecord, at timestamp: Date?) -> [Event] {
    switch Value.string(record, "subtype") {
    case "turn_duration":
      // Every tool of the turn has reported by now; a tool without a result never will.
      pendingTools.removeAll()
      let turn = Event.Turn(status: .completed, durationMs: Value.int(record, "durationMs"))
      return [Event(.turnCompleted, .turn(turn), at: timestamp, source: .transcript)]
    case "compact_boundary":
      return [Event(.contextCompacted, .none, at: timestamp, source: .transcript)]
    case "stop_hook_summary":
      guard let errors = record["hookErrors"] as? [Any], !errors.isEmpty else { return [] }
      let notice = Event.Notice(level: .warning, text: "\(errors.count) hook error(s)", subtype: "stop_hook_summary")
      return [Event(.notice, .notice(notice), at: timestamp, source: .transcript)]
    case "informational", "away_summary":
      guard let content = Value.string(record, "content"), !content.isEmpty else { return [] }
      let level: Event.NoticeLevel = Value.string(record, "level") == "notice" ? .warning : .info
      let notice = Event.Notice(
        level: level, text: Value.title(content, limit: 200), subtype: Value.string(record, "subtype"))
      return [Event(.notice, .notice(notice), at: timestamp, source: .transcript)]
    default:
      return []
    }
  }

  /// `enqueue` carries the text; `dequeue` names nothing and releases the oldest queued
  /// message; `remove` and `popAll` carry the text they take back.
  private mutating func queueEvents(_ record: MirrorConversationRecord, at timestamp: Date?) -> [Event] {
    let content = Value.string(record, "content")
    let reason = Value.string(record, "reason")
    func unqueued(_ text: String) -> Event {
      let message = Event.Message(text: .init(text, limit: 512), origin: .queued, reason: reason)
      return Event(.userUnqueued, .message(message), at: timestamp, source: .transcript)
    }
    switch Value.string(record, "operation") {
    case "enqueue":
      guard let content else { return [] }
      queued.append(content)
      let message = Event.Message(text: .init(content, limit: 512), origin: .queued)
      return [Event(.userQueued, .message(message), at: timestamp, source: .transcript)]
    case "dequeue":
      guard !queued.isEmpty else { return [] }
      return [unqueued(queued.removeFirst())]
    case "remove":
      guard let content else { return [] }
      if let index = queued.firstIndex(of: content) { queued.remove(at: index) }
      return [unqueued(content)]
    case "popAll":
      let texts = queued.isEmpty ? [content].compactMap { $0 } : queued
      queued.removeAll()
      return texts.map(unqueued)
    default:
      return []
    }
  }

  private mutating func titleEvents(_ record: MirrorConversationRecord) -> [Event] {
    guard let title = Value.string(record, "aiTitle"), !title.isEmpty, title != lastTitle else { return [] }
    lastTitle = title
    return [Event(.sessionUpdated, .session(.init(title: title)), at: nil, source: .transcript)]
  }

  // MARK: - Helpers

  /// Observed values: `origin.kind` human / task-notification; `turnOrigin` human / scheduled /
  /// sdk / task_notification.
  private static func origin(of record: MirrorConversationRecord) -> Event.MessageOrigin {
    let raw = Value.object(record, "origin").flatMap { Value.string($0, "kind") } ?? Value.string(record, "turnOrigin")
    switch raw {
    case "human": return .human
    case "queued": return .queued
    case "scheduled", "sdk", "automation", "dispatch": return .automation
    case "task_notification", "task-notification", "system": return .system
    default: return .other
    }
  }

  private static func tag(_ name: String, in text: String) -> String? {
    guard let open = text.range(of: "<\(name)>"),
      let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
    else { return nil }
    return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func outcome(of decision: MirrorConversationRecord) -> Event.PromptOutcome {
    switch Value.string(decision, "decision") {
    case "accept": .allowed
    case "reject": .denied
    default: .unknown
    }
  }
}

/// The kind Claude Code reads from a thinking block's signature: a base64 protobuf whose field
/// 2 → 1 → 8 holds `narration` for thinking it shows in the pane as a reply (Claude Code
/// 2.1.319). Anything that does not decode to exactly that is hidden thinking.
nonisolated enum ClaudeThinkingSignature {
  static func isNarration(_ signature: String?) -> Bool {
    guard let signature, let data = Data(base64Encoded: signature) else { return false }
    let bytes = [UInt8](data)
    guard let outer = field(2, in: bytes[...]), let inner = field(1, in: outer), let kind = field(8, in: inner)
    else { return false }
    return Array(kind) == Array("narration".utf8)
  }

  /// The last length-delimited field `number` of a protobuf message, as Claude Code decodes it:
  /// the whole message must parse, and a repeated field keeps its last value. Nil when the field
  /// is missing or any part of the message is malformed.
  static func field(_ number: UInt64, in message: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
    var found: ArraySlice<UInt8>?
    var index = message.startIndex
    func varint() -> UInt64? {
      var value: UInt64 = 0
      var shift: UInt64 = 0
      while index < message.endIndex, shift < 64 {
        let byte = message[index]
        index += 1
        value |= UInt64(byte & 0x7F) << shift
        if byte < 0x80 { return value }
        shift += 7
      }
      return nil
    }
    while index < message.endIndex {
      guard let key = varint() else { return nil }
      switch key & 7 {
      case 0:
        guard varint() != nil else { return nil }
      case 1:
        guard message.endIndex - index >= 8 else { return nil }
        index += 8
      case 2:
        guard let length = varint(), length <= UInt64(message.endIndex - index) else { return nil }
        let value = message[index..<(index + Int(length))]
        index += Int(length)
        if key >> 3 == number { found = value }
      case 5:
        guard message.endIndex - index >= 4 else { return nil }
        index += 4
      default:
        return nil
      }
    }
    return found
  }
}
