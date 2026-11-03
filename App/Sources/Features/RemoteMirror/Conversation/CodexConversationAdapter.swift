import Foundation

/// Codex's `~/.codex/sessions/.../rollout-*.jsonl` (docs-ai 087). A rollout records items only
/// when they complete: a command appears with its exit code and output in one
/// `item_completed`, so a tool start and its end are emitted together. Turn boundaries
/// (`task_started` / `task_complete`) are immediate. Approval prompts are not in the file.
nonisolated struct CodexConversationAdapter: MirrorConversationAdapter {
  private typealias Event = MirrorConversationEvent
  private typealias Value = MirrorConversationRecordValue

  let agent = DetectedAgent.codex
  private var model: String?
  /// A 0.166 rollout records one compaction twice: a `compacted` record and a
  /// `ContextCompaction` item a few milliseconds apart.
  private var lastCompaction: Date?

  mutating func bootstrap(_ record: MirrorConversationRecord) -> [MirrorConversationEvent] {
    guard Value.string(record, "type") == "session_meta" else { return [] }
    return events(for: record)
  }

  mutating func events(for record: MirrorConversationRecord) -> [MirrorConversationEvent] {
    guard let type = Value.string(record, "type") else { return [] }
    let timestamp = Value.timestamp(record)
    let payload = Value.object(record, "payload") ?? [:]
    switch type {
    case "session_meta":
      let session = Event.Session(
        id: Value.string(payload, "id"), cwd: Value.string(payload, "cwd"),
        version: Value.string(payload, "cli_version"))
      return [Event(.sessionStarted, .session(session), at: timestamp, source: .transcript)]
    case "turn_context":
      return modelUpdate(Value.string(payload, "model"), at: timestamp)
    case "compacted":
      return compaction(at: timestamp)
    case "event_msg":
      return eventMessage(payload, at: timestamp)
    default:
      return []
    }
  }

  private mutating func compaction(at timestamp: Date?) -> [Event] {
    if let timestamp, let last = lastCompaction, abs(timestamp.timeIntervalSince(last)) < 5 { return [] }
    lastCompaction = timestamp
    return [Event(.contextCompacted, .none, at: timestamp, source: .transcript)]
  }

  private mutating func modelUpdate(_ model: String?, at timestamp: Date?) -> [Event] {
    guard let model, !model.isEmpty, model != self.model else { return [] }
    self.model = model
    return [Event(.sessionUpdated, .session(.init(model: model)), at: timestamp, source: .transcript)]
  }

  private mutating func eventMessage(_ payload: MirrorConversationRecord, at timestamp: Date?) -> [Event] {
    switch Value.string(payload, "type") {
    case "task_started":
      return [
        Event(.turnStarted, .turn(.init(id: Value.string(payload, "turn_id"))), at: timestamp, source: .transcript)
      ]
    case "task_complete":
      let turn = Event.Turn(
        id: Value.string(payload, "turn_id"), status: .completed, durationMs: Value.int(payload, "duration_ms"),
        lastMessage: Value.string(payload, "last_agent_message").map { .init($0, limit: 512) })
      return [Event(.turnCompleted, .turn(turn), at: timestamp, source: .transcript)]
    case "turn_aborted":
      let turn = Event.Turn(
        id: Value.string(payload, "turn_id"), status: .aborted, durationMs: Value.int(payload, "duration_ms"),
        reason: Value.string(payload, "reason"))
      return [Event(.turnCompleted, .turn(turn), at: timestamp, source: .transcript)]
    case "thread_settings_applied":
      return modelUpdate(Value.object(payload, "thread_settings").flatMap { Value.string($0, "model") }, at: timestamp)
    case "item_completed":
      return itemEvents(payload, at: timestamp)
    default:
      return []
    }
  }

  private mutating func itemEvents(_ payload: MirrorConversationRecord, at timestamp: Date?) -> [Event] {
    guard let item = Value.object(payload, "item"), let type = Value.string(item, "type") else { return [] }
    let started = Value.epochMilliseconds(payload, "started_at_ms")
    let completed = Value.epochMilliseconds(payload, "completed_at_ms") ?? timestamp
    switch type {
    case "UserMessage":
      let images = Value.imageCount(item["content"])
      guard let text = Value.blockText(item["content"]) ?? (images > 0 ? "" : nil) else { return [] }
      let message = Event.Message(text: .init(text), origin: .human, images: images > 0 ? images : nil)
      return [Event(.userMessage, .message(message), at: started ?? completed, source: .transcript)]
    case "AgentMessage":
      guard let text = Value.blockText(item["content"]), !text.isEmpty else { return [] }
      let phase: Event.MessagePhase = Value.string(item, "phase") == "final_answer" ? .final : .commentary
      return [
        Event(.assistantMessage, .message(.init(text: .init(text), phase: phase)), at: completed, source: .transcript)
      ]
    case "Reasoning":
      let summary = (item["summary_text"] as? [String])?.joined(separator: "\n") ?? Value.string(item, "summary_text")
      let reasoning = Event.Reasoning(summary: summary.flatMap { $0.isEmpty ? nil : .init($0, limit: 512) })
      return [Event(.assistantReasoning, .reasoning(reasoning), at: completed, source: .transcript)]
    case "ContextCompaction":
      return compaction(at: completed)
    case "CommandExecution", "FileChange", "McpToolCall", "Extension", "ImageView", "DynamicToolCall":
      return toolEvents(item, type: type, started: started, completed: completed)
    default:
      return []
    }
  }

  private func toolEvents(_ item: MirrorConversationRecord, type: String, started: Date?, completed: Date?) -> [Event] {
    let id = Value.string(item, "id") ?? UUID().uuidString
    let shape = Self.describe(item, type: type)
    let start = Event.ToolStart(
      id: id, name: shape.name, kind: shape.kind, title: shape.title, command: shape.command, path: shape.path,
      cwd: Value.string(item, "cwd").map(Self.path(fromFileURL:)), changedPaths: shape.changedPaths)
    let duration = started.flatMap { start in completed.map { Int($0.timeIntervalSince(start) * 1000) } }
    let end = Event.ToolEnd(
      id: id, name: shape.name, status: Self.status(Value.string(item, "status")),
      exitCode: Value.int(item, "exit_code"),
      output: Self.output(item, type: type).map { .init($0) },
      diff: type == "FileChange"
        ? Self.fileChangeDiff(item).map { .init($0, limit: MirrorBoundedText.diffLimit) } : nil,
      durationMs: duration)
    return [
      Event(.toolStarted, .toolStart(start), at: started ?? completed, source: .transcript),
      Event(.toolCompleted, .toolEnd(end), at: completed, source: .transcript),
    ]
  }

  private struct ToolShape {
    var kind: Event.ToolKind
    var name: String
    var title: String
    var command: String?
    var path: String?
    var changedPaths: [String]?
  }

  private static func describe(_ item: MirrorConversationRecord, type: String) -> ToolShape {
    switch type {
    case "CommandExecution":
      let command = (item["command"] as? [String])?.joined(separator: " ") ?? Value.string(item, "command") ?? ""
      return ToolShape(kind: .shell, name: type, title: Value.title(command), command: command)
    case "FileChange":
      let paths = (Value.object(item, "changes") ?? [:]).keys.map(path(fromFileURL:)).sorted()
      return ToolShape(kind: .edit, name: type, title: Value.title(paths.joined(separator: ", ")), changedPaths: paths)
    case "McpToolCall":
      let name = [Value.string(item, "server"), Value.string(item, "tool")].compactMap { $0 }.joined(separator: "/")
      return ToolShape(kind: .mcp, name: name.isEmpty ? type : name, title: name)
    case "Extension":
      let name = Value.string(item, "kind") ?? type
      return ToolShape(kind: .web, name: name, title: Value.title(Value.string(item, "query") ?? name))
    case "ImageView":
      let path = Value.string(item, "path").map(path(fromFileURL:))
      return ToolShape(kind: .read, name: type, title: path ?? "", path: path)
    default:
      let name = Value.string(item, "tool") ?? type
      return ToolShape(kind: .other, name: name, title: name)
    }
  }

  private static func status(_ raw: String?) -> Event.ToolStatus {
    switch raw {
    case nil, "completed": .succeeded
    case "failed": .error
    default: .interrupted
    }
  }

  private static func output(_ item: MirrorConversationRecord, type: String) -> String? {
    switch type {
    case "CommandExecution": Value.string(item, "aggregated_output")
    case "FileChange":
      [Value.string(item, "stdout"), Value.string(item, "stderr")].compactMap { $0 }.filter { !$0.isEmpty }
        .joined(separator: "\n")
    case "McpToolCall":
      Value.string(item, "error") ?? Value.object(item, "result").flatMap { Value.blockText($0["content"]) }
    case "DynamicToolCall": Value.blockText(item["contentItems"])
    default: nil
    }
  }

  /// One block per changed path: the rollout's unified diff, or the added content as `+` lines.
  private static func fileChangeDiff(_ item: MirrorConversationRecord) -> String? {
    guard let changes = Value.object(item, "changes") else { return nil }
    let blocks = changes.keys.sorted().compactMap { path -> String? in
      guard let change = changes[path] as? MirrorConversationRecord else { return nil }
      var body = Value.string(change, "unified_diff") ?? ""
      if body.isEmpty, let content = Value.string(change, "content") {
        body = content.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
      }
      return "=== \(self.path(fromFileURL: path)) (\(Value.string(change, "type") ?? "update"))\n" + body
    }
    return blocks.isEmpty ? nil : blocks.joined(separator: "\n")
  }

  private static func path(fromFileURL value: String) -> String {
    guard value.hasPrefix("file://"), let url = URL(string: value) else { return value }
    return url.path(percentEncoded: false)
  }
}
