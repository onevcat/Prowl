import Foundation
import Testing

@testable import Prowl

struct MirrorConversationEventTests {
  @Test func boundedTextCutsAtCharacterBoundary() {
    let ascii = MirrorBoundedText("hello world", limit: 5)
    #expect(ascii.text == "hello" && ascii.truncated && ascii.totalBytes == 11)
    let cjk = MirrorBoundedText("日本語", limit: 4)
    #expect(cjk.text == "日" && cjk.truncated && cjk.totalBytes == 9)
    let short = MirrorBoundedText("abc", limit: 3)
    #expect(short.text == "abc" && !short.truncated && short.totalBytes == nil)
  }

  @Test func toolStartedVector() throws {
    let start = MirrorConversationEvent.ToolStart(
      id: "toolu_1", name: "Bash", kind: .shell, title: "List files", command: "ls", background: false)
    let date = try #require(MirrorConversationEvent.parseTimestamp("2026-11-03T14:19:00.754Z"))
    let event = MirrorConversationEvent(.toolStarted, .toolStart(start), at: date, source: .transcript, sequence: 7)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = try #require(String(bytes: encoder.encode(event), encoding: .utf8))
    #expect(
      json
        == #"{"data":{"background":false,"command":"ls","id":"toolu_1","#
        + #""kind":"shell","name":"Bash","title":"List files"},"#
        + #""kind":"tool.started","seq":7,"source":"transcript","ts":"2026-11-03T14:19:00.754Z"}"#)
    let decoded = try JSONDecoder().decode(MirrorConversationEvent.self, from: Data(json.utf8))
    #expect(decoded == event)
  }

  @Test func roundTripsEveryPayloadFamily() throws {
    let text = MirrorBoundedText("hi")
    let events: [MirrorConversationEvent] = [
      .init(
        .sessionStarted, .session(.init(id: "s", cwd: "/x", model: "m", title: "t", version: "1", costUSD: 0.5)),
        at: nil, source: .transcript),
      .init(.sessionChanged, .session(.init(reason: .clear)), at: Date(timeIntervalSince1970: 1), source: .host),
      .init(
        .turnCompleted, .turn(.init(id: "t", origin: .human, status: .completed, durationMs: 10, lastMessage: text)),
        at: nil, source: .transcript),
      .init(
        .userQueued, .message(.init(text: text, origin: .queued, reason: "absorbed_mid_turn")), at: nil,
        source: .transcript),
      .init(.assistantMessage, .message(.init(text: text, phase: .final, model: "m")), at: nil, source: .transcript),
      .init(.assistantReasoning, .reasoning(.init(durationMs: 3, summary: text)), at: nil, source: .transcript),
      .init(
        .toolCompleted,
        .toolEnd(
          .init(id: "i", name: "Bash", status: .error, exitCode: 2, output: text, durationMs: 5, isImage: false)),
        at: nil, source: .transcript),
      .init(
        .agentStatus, .status(.init(state: .blocked, kind: "permission", reason: "osc.blocked.permission")), at: nil,
        source: .osc),
      .init(
        .promptOpened,
        .prompt(
          .init(
            id: "p", kind: .question, title: "Pick", detail: text,
            choices: [.init(id: "a", label: "A", description: "d")],
            questions: [
              .init(id: "0", header: "H", question: "Q?", multiSelect: false, options: [.init(id: "0", label: "x")])
            ],
            freeform: true)), at: nil, source: .transcript),
      .init(
        .promptResolved,
        .prompt(.init(id: "p", kind: .permission, freeform: false, outcome: .denied, decidedBy: "user")), at: nil,
        source: .transcript),
      .init(.subagentCompleted, .subagent(.init(id: "a", type: "Explore", summary: text)), at: nil, source: .hook),
      .init(.notice, .notice(.init(level: .warning, text: "n", subtype: "s")), at: nil, source: .transcript),
      .init(.contextCompacted, .none, at: nil, source: .transcript),
    ]
    for event in events {
      #expect(event.isConsistent)
      let data = try JSONEncoder().encode(event)
      let decoded = try JSONDecoder().decode(MirrorConversationEvent.self, from: data)
      #expect(decoded == event, "\(event.kind)")
    }
  }

  @Test func rejectsUnknownKindsAndMismatchedData() {
    let unknown = Data(#"{"seq":1,"kind":"party.started","source":"host","data":{}}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(MirrorConversationEvent.self, from: unknown) }
    let mismatched = Data(
      #"{"seq":1,"kind":"tool.started","source":"host","data":{"text":{"text":"x","truncated":false}}}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(MirrorConversationEvent.self, from: mismatched) }
    let badTimestamp = Data(#"{"seq":1,"ts":"yesterday","kind":"context.compacted","source":"host","data":{}}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(MirrorConversationEvent.self, from: badTimestamp) }
  }

  @Test func parsesTimestampsWithAndWithoutFractions() {
    #expect(MirrorConversationEvent.parseTimestamp("2026-11-03T14:18:56.620Z") != nil)
    #expect(MirrorConversationEvent.parseTimestamp("2026-11-03T14:18:56Z") != nil)
    #expect(MirrorConversationEvent.parseTimestamp("2026-11-03 14:18:56") == nil)
  }
}
