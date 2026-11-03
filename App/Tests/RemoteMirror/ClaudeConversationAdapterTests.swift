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

  @Test func skipsMetaRecordsAndCountsImages() {
    let events = run([
      base("user", ["isMeta": true, "message": ["content": "injected"]]),
      base(
        "user",
        [
          "message": ["content": [["type": "text", "text": "see"], ["type": "image", "source": [:]]]],
          "promptId": "p1", "turnOrigin": "human",
        ]),
    ])
    #expect(events.map(\.kind) == [.sessionStarted, .turnStarted, .userMessage])
    guard case .message(let message) = events[2].payload else { return }
    #expect(message.text.text == "see" && message.images == 1)
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
              [
                "type": "tool_use", "id": "toolu_1", "name": "Bash",
                "input": ["command": "ls", "description": "List files"],
              ],
            ],
          ],
          "thinkingDurationMs": 789,
        ]),
      base(
        "user",
        [
          "timestamp": "2026-11-03T14:19:00.250Z",
          "message": [
            "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "boom", "is_error": true]]
          ],
          "toolUseResult": ["stdout": "", "stderr": "boom", "interrupted": false],
        ]),
      base(
        "assistant",
        [
          "message": [
            "content": [["type": "tool_use", "id": "toolu_2", "name": "Read", "input": ["file_path": "/repo/a.swift"]]]
          ]
        ]),
      base(
        "user",
        [
          "message": [
            "content": [
              ["type": "tool_result", "tool_use_id": "toolu_2", "content": [["type": "text", "text": "ok"]]]
            ]
          ],
          "toolUseResult": ["interrupted": true],
        ]),
    ])
    let kinds = events.map(\.kind)
    #expect(
      kinds == [
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

  @Test func opensPromptsForQuestionsAndPlans() {
    let question: [String: Any] = [
      "type": "tool_use", "id": "toolu_q", "name": "AskUserQuestion",
      "input": [
        "questions": [
          [
            "question": "Which?", "header": "Pick", "multiSelect": false,
            "options": [["label": "A", "description": "first"], ["label": "B"]],
          ]
        ]
      ],
    ]
    let plan: [String: Any] = ["type": "tool_use", "id": "toolu_p", "name": "ExitPlanMode", "input": [:]]
    let events = run([base("assistant", ["message": ["content": [question, plan]]])])
    #expect(events.map(\.kind) == [.sessionStarted, .toolStarted, .promptOpened, .toolStarted, .promptOpened])
    guard case .prompt(let asked) = events[2].payload, case .prompt(let approval) = events[4].payload else { return }
    #expect(asked.id == "toolu_q" && asked.kind == .question && asked.freeform)
    #expect(asked.questions?.first?.question == "Which?" && asked.questions?.first?.header == "Pick")
    #expect(asked.questions?.first?.options.map(\.label) == ["A", "B"])
    #expect(approval.kind == .planApproval && approval.choices?.map(\.id) == ["approve", "reject"])
  }

  @Test func resolvesPromptsFromUserDecisionsOnly() {
    let result: [String: Any] = ["type": "tool_result", "tool_use_id": "toolu_1", "content": "denied"]
    let events = run([
      base(
        "user",
        [
          "message": ["content": [result]],
          "permissionDecision": ["decision": "accept", "source": "config", "reasonType": "mode"],
        ]),
      base(
        "user", ["message": ["content": [result]], "permissionDecision": ["decision": "reject", "source": "user"]]),
    ])
    #expect(events.map(\.kind) == [.sessionStarted, .toolCompleted, .toolCompleted, .promptResolved])
    guard case .prompt(let prompt) = events[3].payload else { return }
    #expect(prompt.id == "toolu_1" && prompt.outcome == .denied && prompt.decidedBy == "user")
  }

  @Test func mapsSystemRecordsQueueTitleAndCost() {
    let events = run([
      base("system", ["subtype": "turn_duration", "durationMs": 59_156]),
      base("system", ["subtype": "compact_boundary", "level": "info"]),
      base("system", ["subtype": "stop_hook_summary", "hookErrors": []]),
      base("system", ["subtype": "stop_hook_summary", "hookErrors": ["x"]]),
      base("system", ["subtype": "informational", "level": "notice", "content": "Model switched\nmore"]),
      ["type": "queue-operation", "operation": "enqueue", "content": "later", "timestamp": "2026-11-03T14:32:19.867Z"],
      ["type": "queue-operation", "operation": "remove", "content": "later", "reason": "absorbed_mid_turn"],
      ["type": "ai-title", "aiTitle": "Mirror flag"],
      ["type": "ai-title", "aiTitle": "Mirror flag"],
      ["type": "cost-state", "totalCostUSD": 1.25],
    ])
    #expect(
      events.map(\.kind) == [
        .sessionStarted, .turnCompleted, .contextCompacted, .notice, .notice, .userQueued, .userUnqueued,
        .sessionUpdated,
        .sessionUpdated,
      ])
    guard case .turn(let turn) = events[1].payload, case .notice(let hook) = events[3].payload,
      case .notice(let info) = events[4].payload, case .message(let queued) = events[5].payload,
      case .message(let removed) = events[6].payload, case .session(let titled) = events[7].payload,
      case .session(let cost) = events[8].payload
    else {
      Issue.record("unexpected payloads")
      return
    }
    #expect(turn.status == .completed && turn.durationMs == 59_156)
    #expect(hook.level == .warning && hook.text == "1 hook error(s)")
    #expect(info.level == .warning && info.text == "Model switched")
    #expect(queued.text.text == "later" && queued.origin == .queued)
    #expect(removed.reason == "absorbed_mid_turn")
    #expect(titled.title == "Mirror flag" && cost.costUSD == 1.25)
  }
}
