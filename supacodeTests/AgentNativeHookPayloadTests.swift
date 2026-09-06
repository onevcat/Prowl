import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct AgentNativeHookPayloadTests {
  @Test func claudePayloadsNormalizeWithoutCopyingAssistantOutput() throws {
    let cases: [(String, AgentSignalEvent)] = [
      ("SessionStart", .sessionStart),
      ("Stop", .turnEnded),
      ("StopFailure", .turnEnded),
      ("PermissionRequest", .needsInput),
      ("Elicitation", .needsInput),
      ("SessionEnd", .sessionEnd),
    ]

    for (nativeEvent, expectedEvent) in cases {
      let payload = Data(
        """
        {
          "hook_event_name": "\(nativeEvent)",
          "session_id": "session-123",
          "cwd": "/tmp/Project Space/界",
          "last_assistant_message": "must not cross the bridge",
          "future_field": {"accepted": true},
          "reason": "completed"
        }
        """.utf8
      )
      let signal = try AgentNativeHookDecoder.decode(
        runtime: .claude,
        nativeEvent: nativeEvent,
        payload: payload
      )

      #expect(signal.event == expectedEvent)
      #expect(signal.nativeEvent == nativeEvent)
      #expect(signal.sessionID == "session-123")
      #expect(signal.cwd == "/tmp/Project Space/界")
      #expect(signal.detail != "must not cross the bridge")
      #expect(signal.event.rawValue == expectedEvent.rawValue)
    }
  }

  @Test func claudeNotificationOnlyAcceptsSupportedAttentionTypes() throws {
    let accepted = Data(
      #"{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"s","cwd":"/tmp/p"}"#
        .utf8
    )
    let signal = try AgentNativeHookDecoder.decode(
      runtime: .claude,
      nativeEvent: "Notification",
      payload: accepted
    )
    #expect(signal.event == .needsInput)
    #expect(signal.detail == "permission_prompt")

    let elicitation = Data(
      #"{"hook_event_name":"Notification","notification_type":"elicitation_dialog","session_id":"s","cwd":"/tmp/p"}"#
        .utf8
    )
    #expect(
      try AgentNativeHookDecoder.decode(runtime: .claude, nativeEvent: "Notification", payload: elicitation).detail
        == "elicitation_dialog"
    )

    // `idle_prompt` fires 60 s after a turn ended while the composer sits empty: the agent is
    // waiting, not blocked on a person, and treating it as `needs-input` would displace the
    // `turn-ended` level that idle waits rely on.
    for rejected in ["idle_prompt", "auth_success", "future_notice"] {
      let ignored = Data(
        #"{"hook_event_name":"Notification","notification_type":"\#(rejected)","session_id":"s","cwd":"/tmp/p"}"#
          .utf8
      )
      #expect(throws: AgentNativeHookDecodeError.unsupportedEvent) {
        try AgentNativeHookDecoder.decode(runtime: .claude, nativeEvent: "Notification", payload: ignored)
      }
    }
  }

  @Test func codexPayloadNormalizesFinalArgAndExcludesMessage() throws {
    let payload = Data(
      #"""
      {
        "type": "agent-turn-complete",
        "thread-id": "thread-123",
        "turn-id": "turn-456",
        "cwd": "/tmp/Project Space/界",
        "last-assistant-message": "secret result",
        "future": true
      }
      """#.utf8
    )
    let signal = try AgentNativeHookDecoder.decode(
      runtime: .codex,
      nativeEvent: "agent-turn-complete",
      payload: payload
    )

    #expect(signal.event == .turnEnded)
    #expect(signal.sessionID == "thread-123")
    #expect(signal.cwd == "/tmp/Project Space/界")
    #expect(signal.detail == nil)
  }

  @Test func malformedUnknownAndOversizedPayloadsFailClosed() {
    #expect(throws: AgentNativeHookDecodeError.malformedPayload) {
      try AgentNativeHookDecoder.decode(
        runtime: .claude,
        nativeEvent: "Stop",
        payload: Data("[]".utf8)
      )
    }
    #expect(throws: AgentNativeHookDecodeError.eventMismatch) {
      try AgentNativeHookDecoder.decode(
        runtime: .claude,
        nativeEvent: "Stop",
        payload: Data(#"{"hook_event_name":"SessionEnd","session_id":"s","cwd":"/tmp"}"#.utf8)
      )
    }
    #expect(throws: AgentNativeHookDecodeError.unsupportedEvent) {
      try AgentNativeHookDecoder.decode(
        runtime: .codex,
        nativeEvent: "future-event",
        payload: Data(#"{"type":"future-event","thread-id":"s","cwd":"/tmp"}"#.utf8)
      )
    }
    #expect(throws: AgentNativeHookDecodeError.payloadTooLarge) {
      try AgentNativeHookDecoder.decode(
        runtime: .codex,
        nativeEvent: "agent-turn-complete",
        payload: Data(repeating: 0, count: AgentNativeHookDecoder.maximumPayloadBytes + 1)
      )
    }
    #expect(throws: AgentNativeHookDecodeError.invalidField) {
      try AgentNativeHookDecoder.decode(
        runtime: .codex,
        nativeEvent: "agent-turn-complete",
        payload: Data(
          "{\"type\":\"agent-turn-complete\",\"thread-id\":\"\(String(repeating: "x", count: 257))\",\"cwd\":\"/tmp\"}"
            .utf8
        )
      )
    }
  }
}
