import Foundation
import Testing

@testable import supacode

struct CodexLogDecoderTests {
  private func record(_ payload: String) -> Data {
    Data("{\"type\":\"event_msg\",\"payload\":\(payload)}".utf8)
  }

  @Test func ignoresInheritedHistoryUntilOwnSettingsBoundary() throws {
    var decoder = CodexLogDecoder(sessionID: "child")
    let start = record(#"{"type":"task_started","turn_id":"turn"}"#)
    #expect(try decoder.consume(start, root: "parent").isEmpty)
    _ = try decoder.consume(record(#"{"type":"thread_settings_applied","thread_id":"child"}"#), root: "parent")
    let events = try decoder.consume(start, root: "parent")
    #expect(events.count == 1)
    if case .childStarted(let root, let child, let work) = events.first {
      #expect(root == "parent" && child == "child" && work == "turn")
    } else {
      Issue.record("Expected own child turn, not inherited parent work")
    }
  }

  @Test func mainBoundaryAndMalformedLifecycle() throws {
    var decoder = CodexLogDecoder(sessionID: "main", isLive: true)
    let events = try decoder.consume(record(#"{"type":"task_started","turn_id":"one"}"#), root: "main")
    #expect(events.count == 1)
    #expect(throws: CodexLogDecoder.Failure.self) {
      try decoder.consume(record(#"{"type":"task_started"}"#), root: "main")
    }
  }

  @Test func childCompletionRetainsItsWorkIdentity() throws {
    var decoder = CodexLogDecoder(sessionID: "main", isLive: true)
    let events = try decoder.consume(
      record(
        #"{"type":"item_completed","item":{"type":"SubAgentActivity","kind":"completed","#
          + #""agent_thread_id":"child","id":"subagent-completed-turn2"}}"#
      ), root: "main")
    if case .childEnded(let root, let child, let work) = events.first {
      #expect(root == "main" && child == "child" && work == "turn2")
    } else {
      Issue.record("Expected scoped child completion")
    }
  }
}
