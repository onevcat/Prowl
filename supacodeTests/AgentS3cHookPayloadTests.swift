import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

/// S3c relays Pi, Oh My Pi, and OpenCode through Prowl's own bundled extensions, which forward
/// the runtime's native event names inside the Claude-shaped envelope (docs-ai 064.010). The
/// tables were measured against Pi 0.84.3, Oh My Pi 18.0.6, and OpenCode 1.18.23.
struct AgentS3cHookPayloadTests {
  @Test func nativeEventTablesMatchTheMeasuredLifecycles() {
    #expect(
      AgentNativeHookDecoder.nativeEvents(for: .pi) == [
        "agent_settled": .turnEnded,
        "session_shutdown": .sessionEnd,
        "session_start": .sessionStart,
      ]
    )
    #expect(
      AgentNativeHookDecoder.nativeEvents(for: .omp) == [
        "session_shutdown": .sessionEnd,
        "session_start": .sessionStart,
        "session_stop": .turnEnded,
        "session_switch": .sessionStart,
        "tool_approval_requested": .needsInput,
      ]
    )
    #expect(
      AgentNativeHookDecoder.nativeEvents(for: .opencode) == [
        "permission.asked": .needsInput,
        "question.asked": .needsInput,
        "session.idle": .turnEnded,
      ]
    )
  }

  /// The decoder tables are the single source for the adapters' declared capabilities, so a
  /// hook the app registers is always one the bridge can decode.
  @Test func adaptersDeclareTheDecoderTables() throws {
    let pairs: [(AgentProfileRuntime, AgentNativeHookRuntime)] = [
      (.claude, .claude), (.codex, .codex), (.copilot, .copilot), (.droid, .droid), (.qoder, .qoder),
      (.pi, .pi), (.omp, .omp), (.opencode, .opencode),
    ]
    for (profileRuntime, hookRuntime) in pairs {
      let capability = try #require(AgentRuntimeAdapterRegistry.profileAdapter(for: profileRuntime)?.signalHooks)
      #expect(capability.runtime == hookRuntime)
      #expect(capability.nativeEvents == AgentNativeHookDecoder.nativeEvents(for: hookRuntime))
      #expect(AgentNativeHookRuntime(rawValue: profileRuntime.rawValue) == hookRuntime)
    }
    // OpenCode is non-announcing like Codex: no SessionStart, so ordinary events may rotate.
    #expect(!AgentNativeHookDecoder.nativeEvents(for: .opencode).values.contains(.sessionStart))
    #expect(AgentNativeHookDecoder.nativeEvents(for: .codex).values.contains(.sessionStart) == false)
  }

  @Test func relayedNativeEventsDecodeThroughTheClaudeShapedEnvelope() throws {
    struct RelayedEvent {
      let runtime: AgentNativeHookRuntime
      let nativeEvent: String
      let expected: AgentSignalEvent
      let reason: String?
    }
    let cases = [
      RelayedEvent(runtime: .pi, nativeEvent: "session_start", expected: .sessionStart, reason: "startup"),
      RelayedEvent(runtime: .pi, nativeEvent: "agent_settled", expected: .turnEnded, reason: nil),
      RelayedEvent(runtime: .pi, nativeEvent: "session_shutdown", expected: .sessionEnd, reason: "quit"),
      RelayedEvent(runtime: .omp, nativeEvent: "session_switch", expected: .sessionStart, reason: nil),
      RelayedEvent(runtime: .omp, nativeEvent: "session_stop", expected: .turnEnded, reason: nil),
      RelayedEvent(runtime: .omp, nativeEvent: "tool_approval_requested", expected: .needsInput, reason: "write"),
      RelayedEvent(runtime: .opencode, nativeEvent: "session.idle", expected: .turnEnded, reason: nil),
      RelayedEvent(runtime: .opencode, nativeEvent: "permission.asked", expected: .needsInput, reason: "edit"),
      RelayedEvent(runtime: .opencode, nativeEvent: "question.asked", expected: .needsInput, reason: nil),
    ]
    for relayed in cases {
      let (runtime, nativeEvent, expected, reason) = (
        relayed.runtime, relayed.nativeEvent, relayed.expected, relayed.reason
      )
      let reasonField = reason.map { #""reason": "\#($0)","# } ?? ""
      let payload = Data(
        """
        {
          "hook_event_name": "\(nativeEvent)",
          "session_id": "01a03d4f-81b2-7d06-8517-387c351fef25",
          "cwd": "/tmp/Project Space/界",
          \(reasonField)
          "last_assistant_message": "must not cross the bridge",
          "messages": [{"role": "assistant"}]
        }
        """.utf8
      )
      let signal = try AgentNativeHookDecoder.decode(runtime: runtime, nativeEvent: nativeEvent, payload: payload)
      #expect(signal.event == expected)
      #expect(signal.nativeEvent == nativeEvent)
      #expect(signal.sessionID == "01a03d4f-81b2-7d06-8517-387c351fef25")
      #expect(signal.cwd == "/tmp/Project Space/界")
      #expect(signal.detail == reason)
    }
  }

  /// Events the extensions are told not to forward stay undecodable, so a future extension
  /// (or runtime) sending them cannot create a false edge: Pi/OMP `agent_end` fires per
  /// sub-agent, OpenCode `session.status` duplicates `session.idle`, and the `*.replied`
  /// events mean the block is over, not that one began.
  @Test func excludedNativeEventsAreRejected() {
    let rejected: [(AgentNativeHookRuntime, String)] = [
      (.pi, "agent_end"), (.pi, "turn_end"), (.pi, "input"),
      (.omp, "agent_end"), (.omp, "agent_settled"), (.omp, "tool_approval_resolved"),
      (.opencode, "session.status"), (.opencode, "session.created"), (.opencode, "session.error"),
      (.opencode, "permission.replied"), (.opencode, "question.replied"), (.opencode, "session.deleted"),
      (.pi, "Stop"), (.opencode, "SessionStart"),
    ]
    for (runtime, nativeEvent) in rejected {
      let payload = Data(
        #"{"hook_event_name": "\#(nativeEvent)", "session_id": "s", "cwd": "/tmp/p"}"#.utf8
      )
      #expect(throws: AgentNativeHookDecodeError.unsupportedEvent) {
        try AgentNativeHookDecoder.decode(runtime: runtime, nativeEvent: nativeEvent, payload: payload)
      }
    }
  }

  @Test func rawValuesRoundTripWithProfileRuntimesAndPublicSources() {
    for runtime in [AgentNativeHookRuntime.pi, .omp, .opencode] {
      #expect(AgentProfileRuntime(rawValue: runtime.rawValue)?.rawValue == runtime.rawValue)
    }
    #expect(AgentSignal.Source.hook(runtime: .pi, event: "agent_settled").payloadName == "hook_pi")
    #expect(AgentSignal.Source.hook(runtime: .omp, event: "session_stop").payloadName == "hook_omp")
    #expect(AgentSignal.Source.hook(runtime: .opencode, event: "session.idle").payloadName == "hook_opencode")
  }
}
