import Foundation
import Testing

@testable import Prowl

struct ClaudeConversationAdapterTests {
  private typealias Event = MirrorConversationEvent

  private func run(_ records: [[String: Any]]) -> [Event] {
    var adapter = ClaudeConversationAdapter()
    let events = records.flatMap { adapter.events(for: $0) }
    let consistent = events.allSatisfy(\.isConsistent)
    #expect(consistent)
    return events
  }

  private func base(_ type: String, _ fields: [String: Any]) -> [String: Any] {
    var record: [String: Any] = [
      "type": type, "sessionId": "sess-1", "cwd": "/repo", "version": "2.1.317",
      "timestamp": "2026-11-03T14:18:56.620Z", "uuid": UUID().uuidString,
    ]
    record.merge(fields) { _, new in new }
    return record
  }

  private func toolUse(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
    ["type": "tool_use", "id": id, "name": name, "input": input]
  }

  private func toolResult(_ id: String, _ content: Any = "ok", isError: Bool = false) -> [String: Any] {
    ["type": "tool_result", "tool_use_id": id, "content": content, "is_error": isError]
  }

  @Test func announcesSessionOnceAndMapsHumanPrompt() {
    let events = run([
      base("user", ["message": ["role": "user", "content": "hello"], "promptId": "p1", "origin": ["kind": "human"]]),
      base("user", ["message": ["role": "user", "content": "again"], "promptId": "p2", "turnOrigin": "human"]),
    ])
    #expect(events.map(\.kind) == [.sessionStarted, .turnStarted, .userMessage, .turnStarted, .userMessage])
    guard case .session(let session) = events[0].payload, case .turn(let turn) = events[1].payload,
      case .message(let message) = events[2].payload
    else {
      Issue.record("unexpected payloads")
      return
    }
    #expect(session.id == "sess-1" && session.cwd == "/repo" && session.version == "2.1.317")
    #expect(turn.id == "p1" && turn.origin == .human)
    #expect(message.text.text == "hello" && message.origin == .human)
    #expect(events[1].timestamp == MirrorConversationEvent.parseTimestamp("2026-11-03T14:18:56.620Z"))
  }

  @Test func bootstrapAnnouncesOnlyTheSession() {
    var adapter = ClaudeConversationAdapter()
    let first = adapter.bootstrap(["type": "mode", "sessionId": "sess-1"])
    #expect(first.isEmpty)
    let second = adapter.bootstrap(base("user", ["message": ["content": "hello"], "promptId": "p"]))
    #expect(second.map(\.kind) == [.sessionStarted])
    #expect(
      adapter.events(for: base("user", ["message": ["content": "later"]])).map(\.kind) == [.turnStarted, .userMessage])
  }

  @Test func generatedUserRecordsAreNotHumanTurns() {
    let events = run([
      base("user", ["isMeta": true, "message": ["content": "injected"]]),
      base(
        "user",
        [
          "isCompactSummary": true, "isVisibleInTranscriptOnly": true,
          "message": ["content": "This session is being continued…"],
        ]),
      base(
        "user",
        ["message": ["content": "<command-name>/model</command-name>\n<command-message>model</command-message>"]]),
      base("user", ["message": ["content": "<local-command-stdout></local-command-stdout>"]]),
      base(
        "user",
        [
          "message": ["content": [["type": "text", "text": "see"], ["type": "image", "source": [:]]]],
          "promptId": "p1", "turnOrigin": "human",
        ]),
    ])
    #expect(events.map(\.kind) == [.sessionStarted, .notice, .turnStarted, .userMessage])
    guard case .notice(let notice) = events[1].payload, case .message(let message) = events[3].payload else {
      Issue.record("unexpected payloads")
      return
    }
    #expect(notice.subtype == "command" && notice.text == "/model")
    #expect(message.text.text == "see" && message.images == 1)
  }

  @Test func mapsObservedOrigins() {
    let events = run([
      base("user", ["message": ["content": "a"], "turnOrigin": "scheduled"]),
      base("user", ["message": ["content": "b"], "origin": ["kind": "task-notification"]]),
      base("user", ["message": ["content": "c"], "turnOrigin": "sdk"]),
    ])
    let origins = events.compactMap { event -> Event.MessageOrigin? in
      if case .turn(let turn) = event.payload { return turn.origin }
      return nil
    }
    #expect(origins == [.automation, .system, .automation])
  }

  /// A thinking-block signature in the shape Claude Code 2.1.319 writes: base64 protobuf with
  /// the kind at field 2 → 1 → 8 (`narration` or `thinking`), next to other fields.
  static func signature(kind: String) -> String {
    func field(_ number: UInt8, _ bytes: [UInt8]) -> [UInt8] { [number << 3 | 2, UInt8(bytes.count)] + bytes }
    return Data(field(2, field(1, [0x08, 0x01] + field(8, Array(kind.utf8))))).base64EncodedString()
  }

  /// Claude Code shows thinking in the pane like a reply only when its signature marks it as
  /// narration; only that text goes as the reasoning summary (PR #1058 review R1-001).
  @Test func onlyNarrationThinkingBecomesTheReasoningSummary() {
    func thinking(_ text: String, signature: String?) -> [String: Any] {
      var block: [String: Any] = ["type": "thinking", "thinking": text]
      if let signature { block["signature"] = signature }
      return base("assistant", ["message": ["content": [block]]])
    }
    let narration = Self.signature(kind: "narration")
    let events = run([
      thinking("Next I check the decoder.", signature: narration),
      thinking("Hidden reasoning.", signature: Self.signature(kind: "thinking")),
      thinking("No signature.", signature: nil),
      thinking("Not base64.", signature: "%%%"),
      thinking("…", signature: narration),
      thinking("  ", signature: narration),
    ])
    let reasonings = events.compactMap { event -> Event.Reasoning? in
      guard case .reasoning(let reasoning) = event.payload else { return nil }
      return reasoning
    }
    #expect(reasonings.map { $0.summary?.text ?? "-" } == ["Next I check the decoder.", "-", "-", "-", "-", "-"])
    #expect(!ClaudeThinkingSignature.isNarration(Data([0x12, 0x7F]).base64EncodedString()))
  }

  @Test func pairsToolUseWithResultAndReportsFailures() {
    let events = run([
      base(
        "assistant",
        [
          "timestamp": "2026-11-03T14:19:00.000Z",
          "message": [
            "model": "claude-fable-5-1",
            "content": [
              ["type": "thinking", "thinking": "…"],
              ["type": "text", "text": "Looking."],
              toolUse("toolu_1", "Bash", ["command": "ls", "description": "List files"]),
            ],
          ],
          "thinkingDurationMs": 789,
        ]),
      base(
        "user",
        [
          "timestamp": "2026-11-03T14:19:00.250Z",
          "message": ["content": [toolResult("toolu_1", "boom", isError: true)]],
          "toolUseResult": ["stdout": "", "stderr": "boom", "interrupted": false],
        ]),
      base("assistant", ["message": ["content": [toolUse("toolu_2", "Read", ["file_path": "/repo/a.swift"])]]]),
      base(
        "user",
        [
          "message": ["content": [toolResult("toolu_2", [["type": "text", "text": "ok"]])]],
          "toolUseResult": ["interrupted": true],
        ]),
    ])
    #expect(
      events.map(\.kind) == [
        .sessionStarted, .assistantReasoning, .assistantMessage, .toolStarted, .toolCompleted, .toolStarted,
        .toolCompleted,
      ])
    guard case .reasoning(let reasoning) = events[1].payload, case .message(let message) = events[2].payload,
      case .toolStart(let start) = events[3].payload, case .toolEnd(let end) = events[4].payload,
      case .toolStart(let read) = events[5].payload, case .toolEnd(let readEnd) = events[6].payload
    else {
      Issue.record("unexpected payloads")
      return
    }
    #expect(reasoning.durationMs == 789)
    #expect(message.model == "claude-fable-5-1")
    #expect(start.kind == .shell && start.title == "List files" && start.command == "ls")
    #expect(end.name == "Bash" && end.status == .error && end.output?.text == "boom" && end.durationMs == 250)
    #expect(read.kind == .read && read.title == "/repo/a.swift" && read.path == "/repo/a.swift")
    #expect(readEnd.status == .interrupted && readEnd.output?.text == "ok")
  }

  @Test func titlesPreferDescriptionsAndPatterns() {
    let events = run([
      base(
        "assistant",
        [
          "message": [
            "content": [
              toolUse(
                "a", "Agent",
                ["prompt": "Long prompt text", "description": "Search the docs", "subagent_type": "Explore"]),
              toolUse("g", "Grep", ["path": "/repo", "pattern": "needle"]),
            ]
          ]
        ])
    ])
    let titles = events.compactMap { event -> String? in
      if case .toolStart(let start) = event.payload { return start.title }
      return nil
    }
    #expect(titles == ["Search the docs", "needle"])
  }

  @Test func editsCarryDiffs() {
    let events = run([
      base(
        "assistant",
        [
          "message": [
            "content": [
              toolUse("e", "Edit", ["file_path": "/repo/a.swift", "old_string": "a", "new_string": "b"]),
              toolUse("w", "Write", ["file_path": "/repo/new.md", "content": "one\ntwo"]),
            ]
          ]
        ]),
      base(
        "user",
        [
          "message": ["content": [toolResult("e")]],
          "toolUseResult": [
            "filePath": "/repo/a.swift",
            "structuredPatch": [["oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1, "lines": ["-a", "+b"]]],
          ],
        ]),
      base(
        "user",
        [
          "message": ["content": [toolResult("w")]],
          "toolUseResult": [
            "type": "create", "filePath": "/repo/new.md", "content": "one\ntwo", "structuredPatch": [],
          ],
        ]),
    ])
    let diffs = events.compactMap { event -> String? in
      if case .toolEnd(let end) = event.payload { return end.diff?.text }
      return nil
    }
    #expect(diffs == ["@@ -1,1 +1,1 @@\n-a\n+b", "+one\n+two"])
  }

  @Test func questionsResolveAsAnsweredNotAsPermissions() {
    let question = toolUse(
      "toolu_q", "AskUserQuestion",
      [
        "questions": [
          [
            "question": "Which?", "header": "Pick", "multiSelect": false,
            "options": [["label": "A", "description": "first"], ["label": "B"]],
          ]
        ]
      ])
    let plan = toolUse("toolu_p", "ExitPlanMode", [:])
    let events = run([
      base("assistant", ["message": ["content": [question, plan]]]),
      base(
        "user",
        [
          "message": ["content": [toolResult("toolu_q", "User answered")]],
          "toolUseResult": ["questions": [], "answers": ["Which?": "A"]],
          "permissionDecision": ["decision": "accept", "source": "user_temporary", "grantScope": "once"],
        ]),
      base(
        "user",
        [
          "message": ["content": [toolResult("toolu_p", "rejected", isError: true)]],
          "permissionDecision": ["decision": "accept", "source": "config", "reasonType": "mode"],
        ]),
    ])
    #expect(
      events.map(\.kind) == [
        .sessionStarted, .toolStarted, .promptOpened, .toolStarted, .promptOpened, .toolCompleted, .promptResolved,
        .toolCompleted, .promptResolved,
      ])
    guard case .prompt(let asked) = events[2].payload, case .prompt(let approval) = events[4].payload,
      case .prompt(let answered) = events[6].payload, case .prompt(let dismissed) = events[8].payload
    else {
      Issue.record("unexpected payloads")
      return
    }
    #expect(asked.id == "toolu_q" && asked.kind == .question && asked.freeform)
    #expect(asked.questions?.first?.question == "Which?" && asked.questions?.first?.header == "Pick")
    #expect(asked.questions?.first?.options.map(\.label) == ["A", "B"])
    #expect(approval.kind == .planApproval && approval.choices?.map(\.id) == ["approve", "reject"])
    #expect(answered.id == "toolu_q" && answered.kind == .question && answered.outcome == .answered)
    #expect(dismissed.id == "toolu_p" && dismissed.kind == .planApproval && dismissed.outcome == .dismissed)
  }

  @Test func permissionDecisionsResolveOnlyForPeople() {
    let events = run([
      base(
        "assistant",
        [
          "message": [
            "content": [
              toolUse("b1", "Bash", ["command": "rm x"]), toolUse("b2", "Bash", ["command": "ls"]),
              toolUse("b3", "Bash", ["command": "pwd"]),
            ]
          ]
        ]),
      base(
        "user",
        [
          "message": ["content": [toolResult("b1", "denied", isError: true)]],
          "permissionDecision": ["decision": "reject", "source": "user_temporary"],
        ]),
      base(
        "user",
        [
          "message": ["content": [toolResult("b2")]],
          "permissionDecision": ["decision": "accept", "source": "config", "reasonType": "mode"],
        ]),
      base(
        "user",
        ["message": ["content": [toolResult("b3")]], "permissionDecision": ["decision": "accept", "source": "hook"]]),
    ])
    #expect(
      events.map(\.kind) == [
        .sessionStarted, .toolStarted, .toolStarted, .toolStarted, .toolCompleted, .promptResolved, .toolCompleted,
        .toolCompleted,
      ])
    guard case .prompt(let prompt) = events[5].payload else {
      Issue.record("unexpected payload")
      return
    }
    #expect(
      prompt.id == "b1" && prompt.kind == .permission && prompt.outcome == .denied
        && prompt.decidedBy == "user_temporary")
  }

  @Test func queueOperationsTrackQueuedMessages() {
    let events = run([
      ["type": "queue-operation", "operation": "enqueue", "content": "first", "timestamp": "2026-11-03T14:32:19.867Z"],
      ["type": "queue-operation", "operation": "enqueue", "content": "second"],
      ["type": "queue-operation", "operation": "dequeue"],
      ["type": "queue-operation", "operation": "enqueue", "content": "third"],
      ["type": "queue-operation", "operation": "remove", "content": "third", "reason": "absorbed_mid_turn"],
      ["type": "queue-operation", "operation": "popAll", "content": "second"],
      ["type": "queue-operation", "operation": "dequeue"],
      ["type": "queue-operation", "operation": "enqueue"],
    ])
    let steps = events.compactMap { event -> String? in
      guard case .message(let message) = event.payload else { return nil }
      return "\(event.kind.rawValue):\(message.text.text)\(message.reason.map { ":" + $0 } ?? "")"
    }
    #expect(
      steps == [
        "user.queued:first", "user.queued:second", "user.unqueued:first", "user.queued:third",
        "user.unqueued:third:absorbed_mid_turn", "user.unqueued:second",
      ])
  }

  @Test func mapsSystemRecordsTitleAndCost() {
    let events = run([
      base("assistant", ["message": ["content": [toolUse("orphan", "Bash", ["command": "sleep 9"])]]]),
      base("system", ["subtype": "turn_duration", "durationMs": 59_156]),
      base("user", ["message": ["content": [toolResult("orphan", "late")]]]),
      base("system", ["subtype": "compact_boundary", "level": "info"]),
      base("system", ["subtype": "stop_hook_summary", "hookErrors": []]),
      base("system", ["subtype": "stop_hook_summary", "hookErrors": ["x"]]),
      base("system", ["subtype": "informational", "level": "notice", "content": "Model switched\nmore"]),
      base(
        "system",
        ["subtype": "local_command", "level": "info", "content": "<local-command-stdout></local-command-stdout>"]),
      ["type": "ai-title", "aiTitle": "Mirror flag"],
      ["type": "ai-title", "aiTitle": "Mirror flag"],
      ["type": "cost-state", "totalCostUSD": 1.25],
    ])
    #expect(
      events.map(\.kind) == [
        .sessionStarted, .toolStarted, .turnCompleted, .toolCompleted, .contextCompacted, .notice, .notice,
        .sessionUpdated,
        .sessionUpdated,
      ])
    guard case .turn(let turn) = events[2].payload, case .toolEnd(let late) = events[3].payload,
      case .notice(let hook) = events[5].payload, case .notice(let info) = events[6].payload,
      case .session(let titled) = events[7].payload, case .session(let cost) = events[8].payload
    else {
      Issue.record("unexpected payloads")
      return
    }
    #expect(turn.status == .completed && turn.durationMs == 59_156)
    // The turn closed before the result, so the name is gone but the completion still lands.
    #expect(late.name == nil && late.status == .succeeded)
    #expect(hook.level == .warning && hook.text == "1 hook error(s)")
    #expect(info.level == .warning && info.text == "Model switched")
    #expect(titled.title == "Mirror flag" && cost.costUSD == 1.25)
  }
}
