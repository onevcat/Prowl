import Foundation
import Testing

@testable import supacode

struct AgentTranscriptResultReaderTests {
  @Test func decodesLatestClosedCodexTaskCompletion() throws {
    let result = AgentTranscriptResultReader.decode(
      agent: .codex,
      jsonl: try jsonl([
        codexCompletion(turnID: "turn-1", completedAt: 1_786_435_200, text: "First result"),
        codexCompletion(turnID: "turn-2", completedAt: 1_786_435_260, text: "Final result"),
      ]),
      maxBytes: 1_024
    )

    #expect(result.state == .complete)
    #expect(result.text == "Final result")
  }

  @Test func decodesCodexCompletionWithNumericTimestamp() throws {
    let result = AgentTranscriptResultReader.decode(
      agent: .codex,
      jsonl: try jsonl([
        codexCompletion(turnID: "turn-1", completedAt: 1_786_438_335, text: "Final result")
      ]),
      maxBytes: 1_024
    )

    #expect(result.state == .complete)
    #expect(result.text == "Final result")
  }

  @Test func rejectsCodexCompletionWithoutUsableIdentityOrText() throws {
    let emptyTurnID = AgentTranscriptResultReader.decode(
      agent: .codex,
      jsonl: try jsonl([
        codexCompletion(turnID: "", completedAt: 1_786_438_335, text: "Final result")
      ]),
      maxBytes: 1_024
    )
    let emptyText = AgentTranscriptResultReader.decode(
      agent: .codex,
      jsonl: try jsonl([
        codexCompletion(turnID: "turn-1", completedAt: 1_786_438_335, text: "")
      ]),
      maxBytes: 1_024
    )

    #expect(emptyTurnID.state == .incomplete)
    #expect(emptyText.state == .incomplete)
  }

  @Test func rejectsCodexCompletionWithNonIntegerTimestamp() throws {
    let result = AgentTranscriptResultReader.decode(
      agent: .codex,
      jsonl: try jsonl([
        codexCompletion(turnID: "turn-1", completedAt: 1_786_438_335.5, text: "Final result")
      ]),
      maxBytes: 1_024
    )

    #expect(result.state == .incomplete)
    #expect(result.text == nil)
  }

  @Test func rejectsCodexCompletionWithErrorOrMissingMessage() throws {
    var errorPayload =
      codexCompletion(
        turnID: "turn-1",
        completedAt: 1_786_438_335,
        text: "Partial result"
      )["payload"] as? [String: Any] ?? [:]
    errorPayload["error"] = ["message": "stream disconnected"]
    let errored = AgentTranscriptResultReader.decode(
      agent: .codex,
      jsonl: try jsonl([["type": "event_msg", "payload": errorPayload]]),
      maxBytes: 1_024
    )
    let missingMessage = AgentTranscriptResultReader.decode(
      agent: .codex,
      jsonl: try jsonl([
        [
          "type": "event_msg",
          "payload": [
            "type": "task_complete",
            "turn_id": "turn-1",
            "completed_at": 1_786_438_335,
            "last_agent_message": NSNull(),
          ],
        ]
      ]),
      maxBytes: 1_024
    )

    #expect(errored.state == .incomplete)
    #expect(missingMessage.state == .incomplete)
  }

  @Test func acceptsCompletedCodexResultMentioningMaxTokens() throws {
    let result = AgentTranscriptResultReader.decode(
      agent: .codex,
      jsonl: try jsonl([
        codexCompletion(
          turnID: "turn-1",
          completedAt: 1_786_435_200,
          text: "Use max_tokens to configure the output limit."
        )
      ]),
      maxBytes: 1_024
    )

    #expect(result.state == .complete)
    #expect(result.text == "Use max_tokens to configure the output limit.")
  }

  @Test func rejectsLatestBudgetLimitedCodexTurnWithoutReturningEarlierResult() throws {
    let result = AgentTranscriptResultReader.decode(
      agent: .codex,
      jsonl: try jsonl([
        codexCompletion(turnID: "turn-1", completedAt: 1_786_435_200, text: "Earlier result"),
        codexAbort(turnID: "turn-2", completedAt: 1_786_435_260, reason: "budget_limited"),
      ]),
      maxBytes: 1_024
    )

    #expect(result.state == .incomplete)
    #expect(result.text == nil)
  }

  @Test func followsClaudeTurnDurationParentChainToClosedAssistantText() throws {
    let result = AgentTranscriptResultReader.decode(
      agent: .claude,
      jsonl: try jsonl([
        claudeAssistant(uuid: "assistant-1", sessionID: "session-1", text: "Claude final result"),
        claudeSystem(
          subtype: "stop_hook_summary",
          uuid: "summary-1",
          sessionID: "session-1",
          parentUUID: "assistant-1"
        ),
        claudeSystem(
          subtype: "turn_duration",
          uuid: "duration-1",
          sessionID: "session-1",
          parentUUID: "summary-1"
        ),
      ]),
      maxBytes: 1_024
    )

    #expect(result.state == .complete)
    #expect(result.text == "Claude final result")
  }

  @Test func rejectsClaudeToolOnlyAssistantTurnAsIncomplete() throws {
    let result = AgentTranscriptResultReader.decode(
      agent: .claude,
      jsonl: try jsonl([
        claudeAssistant(uuid: "assistant-1", sessionID: "session-1", content: [["type": "tool_use", "name": "Bash"]]),
        claudeSystem(
          subtype: "turn_duration",
          uuid: "duration-1",
          sessionID: "session-1",
          parentUUID: "assistant-1"
        ),
      ]),
      maxBytes: 1_024
    )

    #expect(result.state == .incomplete)
    #expect(result.text == nil)
  }

  @Test func rejectsUnclosedJSONLWithoutReturningPartialText() throws {
    let jsonl =
      try jsonl([
        codexCompletion(turnID: "turn-1", completedAt: 1_786_435_200, text: "Final result")
      ]) + "{\"type\":\"event_msg\"\n"
    let result = AgentTranscriptResultReader.decode(agent: .codex, jsonl: jsonl, maxBytes: 1_024)

    #expect(result.state == .incomplete)
    #expect(result.text == nil)
  }

  @Test func reportsOversizedCompleteResultWithoutTruncatingIt() throws {
    let result = AgentTranscriptResultReader.decode(
      agent: .codex,
      jsonl: try jsonl([
        codexCompletion(turnID: "turn-1", completedAt: 1_786_435_200, text: "0123456789")
      ]),
      maxBytes: 5
    )

    #expect(result.state == .tooLarge)
    #expect(result.text == nil)
  }

  @Test func readsCompleteResultAtWorstCaseJSONEscapingSize() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "prowl-result-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let text = String(repeating: "\u{1}", count: 400_000)
    try jsonl([
      codexCompletion(turnID: "turn-1", completedAt: 1_786_435_200, text: text)
    ]).write(to: url, atomically: true, encoding: .utf8)

    let result = AgentTranscriptResultReader.read(agent: .codex, at: url, maxBytes: 400_000)

    #expect(result.state == .complete)
    #expect(result.text == text)
  }

  @Test func readsOnlyTheBoundedTranscriptTail() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "prowl-result-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let oversizedHistory =
      "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"text\":\""
      + String(repeating: "x", count: 1_100_000) + "\"}}\n"
    let completion = try jsonl([
      codexCompletion(turnID: "turn-1", completedAt: 1_786_435_200, text: "Final result")
    ])
    try (oversizedHistory + completion).write(to: url, atomically: true, encoding: .utf8)

    let result = AgentTranscriptResultReader.read(agent: .codex, at: url, maxBytes: 1_024)

    #expect(result.state == .complete)
    #expect(result.text == "Final result")
  }

  private func codexCompletion(
    turnID: String,
    completedAt: Any,
    text: String
  ) -> [String: Any] {
    [
      "type": "event_msg",
      "payload": [
        "type": "task_complete",
        "turn_id": turnID,
        "completed_at": completedAt,
        "last_agent_message": text,
      ],
    ]
  }

  private func codexAbort(
    turnID: String,
    completedAt: Any,
    reason: String
  ) -> [String: Any] {
    [
      "type": "event_msg",
      "payload": [
        "type": "turn_aborted",
        "turn_id": turnID,
        "completed_at": completedAt,
        "reason": reason,
      ],
    ]
  }

  private func claudeAssistant(
    uuid: String,
    sessionID: String,
    text: String? = nil,
    content: [[String: Any]]? = nil
  ) -> [String: Any] {
    [
      "type": "assistant",
      "uuid": uuid,
      "sessionId": sessionID,
      "message": [
        "stop_reason": "end_turn",
        "content": content ?? [["type": "text", "text": text ?? ""]],
      ],
    ]
  }

  private func claudeSystem(
    subtype: String,
    uuid: String,
    sessionID: String,
    parentUUID: String
  ) -> [String: Any] {
    [
      "type": "system",
      "subtype": subtype,
      "uuid": uuid,
      "sessionId": sessionID,
      "parentUuid": parentUUID,
    ]
  }

  private func jsonl(_ records: [[String: Any]]) throws -> String {
    try records.map { record in
      let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
      return try #require(String(data: data, encoding: .utf8)) + "\n"
    }.joined()
  }
}
