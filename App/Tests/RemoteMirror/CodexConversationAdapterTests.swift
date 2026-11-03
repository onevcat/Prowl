import Foundation
import Testing

@testable import Prowl

struct CodexConversationAdapterTests {
  private typealias Event = MirrorConversationEvent

  private func run(_ records: [[String: Any]]) -> [Event] {
    var adapter = CodexConversationAdapter()
    let events = records.flatMap { adapter.events(for: $0) }
    let consistent = events.allSatisfy(\.isConsistent)
    #expect(consistent)
    return events
  }

  private func event(_ payload: [String: Any], at timestamp: String = "2026-11-03T04:33:41.701Z") -> [String: Any] {
    ["type": "event_msg", "timestamp": timestamp, "payload": payload]
  }

  private func completed(
    _ item: [String: Any], started: Int = 1_793_712_821_000, finished: Int = 1_793_712_823_500,
    at timestamp: String = "2026-11-03T04:33:41.701Z"
  ) -> [String: Any] {
    event(
      [
        "type": "item_completed", "item": item, "started_at_ms": started, "completed_at_ms": finished,
        "turn_id": "turn-1",
      ],
      at: timestamp)
  }

  @Test func mapsSessionTurnsAndModel() {
    let events = run([
      [
        "type": "session_meta", "timestamp": "2026-11-03T04:33:40.707Z",
        "payload": ["id": "thread-1", "cwd": "/repo", "cli_version": "0.166.0"],
      ],
      event(["type": "task_started", "turn_id": "turn-1"]),
      ["type": "turn_context", "payload": ["model": "gpt-6.1-sol", "approval_policy": "never"]],
      ["type": "turn_context", "payload": ["model": "gpt-6.1-sol"]],
      event(["type": "thread_settings_applied", "thread_settings": ["model": "gpt-6-astra"]]),
      event(["type": "task_complete", "turn_id": "turn-1", "duration_ms": 1234, "last_agent_message": "Done."]),
      event(["type": "turn_aborted", "turn_id": "turn-2", "duration_ms": 77, "reason": "interrupted"]),
    ])
    #expect(
      events.map(\.kind) == [
        .sessionStarted, .turnStarted, .sessionUpdated, .sessionUpdated, .turnCompleted, .turnCompleted,
      ])
    guard case .session(let session) = events[0].payload, case .turn(let started) = events[1].payload,
      case .session(let model) = events[2].payload, case .session(let newModel) = events[3].payload,
      case .turn(let done) = events[4].payload, case .turn(let aborted) = events[5].payload
    else {
      Issue.record("unexpected payloads")
      return
    }
    #expect(session.id == "thread-1" && session.cwd == "/repo" && session.version == "0.166.0")
    #expect(started.id == "turn-1" && model.model == "gpt-6.1-sol" && newModel.model == "gpt-6-astra")
    #expect(done.status == .completed && done.durationMs == 1234 && done.lastMessage?.text == "Done.")
    #expect(
      aborted.status == .aborted && aborted.id == "turn-2" && aborted.durationMs == 77
        && aborted.reason == "interrupted")
  }

  @Test func bootstrapAnnouncesOnlySessionMeta() {
    var adapter = CodexConversationAdapter()
    #expect(adapter.bootstrap(event(["type": "task_started", "turn_id": "t"])).isEmpty)
    let announced = adapter.bootstrap(["type": "session_meta", "payload": ["id": "thread-9", "cwd": "/x"]])
    #expect(announced.map(\.kind) == [.sessionStarted])
  }

  @Test func oneCompactionProducesOneEvent() {
    let events = run([
      ["type": "compacted", "timestamp": "2026-11-03T04:40:00.000Z", "payload": [:]],
      completed(
        ["type": "ContextCompaction", "id": "c1"], started: 1_793_680_800_006, finished: 1_793_680_800_006,
        at: "2026-11-03T04:40:00.006Z"),
      ["type": "compacted", "timestamp": "2026-11-03T05:10:00.000Z", "payload": [:]],
      completed(
        ["type": "ContextCompaction", "id": "c2"], started: 1_793_682_600_004, finished: 1_793_682_600_004,
        at: "2026-11-03T05:10:00.004Z"),
    ])
    #expect(events.map(\.kind) == [.contextCompacted, .contextCompacted])
  }

  @Test func emitsToolPairsFromCompletedItems() {
    let events = run([
      completed([
        "type": "CommandExecution", "id": "exec-1", "command": ["/bin/zsh", "-lc", "git status"],
        "cwd": "file:///Users/me/repo", "status": "completed", "exit_code": 0, "aggregated_output": "clean\n",
      ]),
      completed([
        "type": "FileChange", "id": "exec-2", "status": "failed",
        "changes": [
          "file:///Users/me/repo/b.md": ["type": "update", "unified_diff": "@@ -1 +1 @@\n-old\n+new"],
          "/Users/me/repo/a.md": ["type": "add", "content": "hello\nworld"],
        ],
        "stdout": "", "stderr": "conflict",
      ]),
      completed([
        "type": "McpToolCall", "id": "exec-3", "server": "node_repl", "tool": "js", "status": "completed",
        "result": ["content": [["type": "text", "text": "42"]]],
      ]),
      completed(["type": "ImageView", "id": "exec-4", "path": "file:///tmp/shot.png"]),
    ])
    #expect(events.count == 8 && events.map(\.kind).allSatisfy { $0 == .toolStarted || $0 == .toolCompleted })
    guard case .toolStart(let shell) = events[0].payload, case .toolEnd(let shellEnd) = events[1].payload,
      case .toolStart(let edit) = events[2].payload, case .toolEnd(let editEnd) = events[3].payload,
      case .toolStart(let mcp) = events[4].payload, case .toolEnd(let mcpEnd) = events[5].payload,
      case .toolStart(let image) = events[6].payload
    else {
      Issue.record("unexpected payloads")
      return
    }
    #expect(shell.kind == .shell && shell.command == "/bin/zsh -lc git status" && shell.cwd == "/Users/me/repo")
    #expect(shellEnd.status == .succeeded && shellEnd.exitCode == 0 && shellEnd.output?.text == "clean\n")
    #expect(shellEnd.durationMs == 2500)
    #expect(events[0].timestamp == Date(timeIntervalSince1970: 1_793_712_821))
    #expect(edit.kind == .edit && edit.changedPaths == ["/Users/me/repo/a.md", "/Users/me/repo/b.md"])
    #expect(editEnd.status == .error && editEnd.output?.text == "conflict")
    #expect(
      editEnd.diff?.text
        == "=== /Users/me/repo/a.md (add)\n+hello\n+world\n=== /Users/me/repo/b.md (update)\n@@ -1 +1 @@\n-old\n+new")
    #expect(mcp.kind == .mcp && mcp.name == "node_repl/js" && mcpEnd.output?.text == "42")
    #expect(image.kind == .read && image.path == "/tmp/shot.png")
  }

  @Test func mapsMessagesReasoningAndIgnoresUnknowns() {
    let events = run([
      completed(["type": "UserMessage", "id": "u1", "content": [["type": "text", "text": "Review this"]]]),
      completed([
        "type": "UserMessage", "id": "u2",
        "content": [
          ["type": "text", "text": "look"], ["type": "local_image", "path": "/tmp/a.png"],
          ["type": "skill", "name": "x"],
        ],
      ]),
      completed([
        "type": "AgentMessage", "id": "m1", "phase": "commentary", "content": [["type": "Text", "text": "On it."]],
      ]),
      completed([
        "type": "AgentMessage", "id": "m2", "phase": "final_answer", "content": [["type": "Text", "text": "READY"]],
      ]),
      completed(["type": "Reasoning", "id": "r1", "summary_text": ["Checking", "files"]]),
      completed(["type": "Reasoning", "id": "r2", "summary_text": []]),
      completed(["type": "SomethingNew", "id": "n1"]),
      [
        "type": "response_item",
        "payload": ["type": "message", "role": "developer", "content": [["type": "input_text", "text": "x"]]],
      ],
    ])
    #expect(
      events.map(\.kind) == [
        .userMessage, .userMessage, .assistantMessage, .assistantMessage, .assistantReasoning, .assistantReasoning,
      ])
    guard case .message(let user) = events[0].payload, case .message(let withImage) = events[1].payload,
      case .message(let commentary) = events[2].payload, case .message(let final) = events[3].payload,
      case .reasoning(let summary) = events[4].payload, case .reasoning(let empty) = events[5].payload
    else {
      Issue.record("unexpected payloads")
      return
    }
    #expect(user.text.text == "Review this" && user.origin == .human)
    #expect(withImage.text.text == "look" && withImage.images == 1)
    #expect(commentary.phase == .commentary && final.phase == .final && final.text.text == "READY")
    #expect(summary.summary?.text == "Checking\nfiles" && empty.summary == nil)
  }
}
