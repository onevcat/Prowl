import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

/// S3b decodes Copilot, Droid, and Qoder through the Claude-shaped path. Their real
/// payloads were captured from Copilot CLI 1.0.80, Factory Droid 0.202.0, and Qoder CLI
/// 1.1.29 (docs-ai 064.008).
struct AgentS3bHookPayloadTests {
  private static let s3bRuntimes: [AgentNativeHookRuntime] = [.copilot, .droid, .qoder]

  @Test func s3bRuntimesShareTheClaudeShapedLifecycleMapping() throws {
    let cases: [(String, AgentSignalEvent)] = [
      ("SessionStart", .sessionStart),
      ("Stop", .turnEnded),
      ("SessionEnd", .sessionEnd),
    ]

    for runtime in Self.s3bRuntimes {
      for (nativeEvent, expected) in cases {
        let payload = Data(
          """
          {
            "hook_event_name": "\(nativeEvent)",
            "session_id": "session-123",
            "cwd": "/tmp/Project Space/界",
            "transcript_path": "/tmp/transcript.jsonl",
            "last_assistant_message": "must not cross the bridge",
            "future_field": {"accepted": true},
            "reason": "complete"
          }
          """.utf8
        )
        let signal = try AgentNativeHookDecoder.decode(
          runtime: runtime,
          nativeEvent: nativeEvent,
          payload: payload
        )

        #expect(signal.event == expected)
        #expect(signal.nativeEvent == nativeEvent)
        #expect(signal.sessionID == "session-123")
        #expect(signal.cwd == "/tmp/Project Space/界")
        #expect(signal.detail != "must not cross the bridge")
      }
    }
  }

  /// Copilot's PascalCase config yields snake_case payloads for lifecycle events but a
  /// mixed-case `Notification`: `hook_event_name` alongside a camelCase `sessionId`. It is
  /// Copilot's only needs-input source, so insisting on `session_id` would silently drop it.
  @Test func copilotNotificationCarriesCamelCaseSessionIdentifier() throws {
    let payload = Data(
      """
      {
        "sessionId": "ef7be551-f465-4de3-99bd-e17facff032d",
        "timestamp": "1787617986906",
        "cwd": "/tmp/project",
        "message": "Run command: touch notifprobe.txt",
        "title": "Permission needed",
        "hook_event_name": "Notification",
        "notification_type": "permission_prompt"
      }
      """.utf8
    )
    let signal = try AgentNativeHookDecoder.decode(
      runtime: .copilot,
      nativeEvent: "Notification",
      payload: payload
    )

    #expect(signal.event == .needsInput)
    #expect(signal.sessionID == "ef7be551-f465-4de3-99bd-e17facff032d")
    #expect(signal.detail == "permission_prompt")
  }

  @Test func s3bNotificationsAcceptOnlyBlockingAttentionTypes() throws {
    for runtime in Self.s3bRuntimes {
      for accepted in ["permission_prompt", "elicitation_dialog"] {
        let signal = try AgentNativeHookDecoder.decode(
          runtime: runtime,
          nativeEvent: "Notification",
          payload: Data(
            """
            {"hook_event_name":"Notification","session_id":"s","cwd":"/tmp",
             "notification_type":"\(accepted)","message":"needs you"}
            """.utf8
          )
        )
        #expect(signal.event == .needsInput)
        #expect(signal.detail == accepted)
      }

      // `idle_prompt` means "waiting", not "blocked on a human", and `auth_success` is
      // informational. Neither may resolve a wait as needs-input.
      for rejected in ["idle_prompt", "auth_success", "shell_completed", "agent_idle"] {
        #expect(throws: AgentNativeHookDecodeError.unsupportedEvent) {
          try AgentNativeHookDecoder.decode(
            runtime: runtime,
            nativeEvent: "Notification",
            payload: Data(
              """
              {"hook_event_name":"Notification","session_id":"s","cwd":"/tmp",
               "notification_type":"\(rejected)"}
              """.utf8
            )
          )
        }
      }
    }
  }

  /// Copilot and Qoder emit `PermissionRequest` even when the permission service
  /// auto-approves and no human is waiting (docs-ai 064.008), so it is never decoded.
  @Test func s3bRuntimesRejectPermissionRequestEntirely() {
    for runtime in Self.s3bRuntimes {
      for nativeEvent in ["PermissionRequest", "PermissionDenied", "Elicitation"] {
        #expect(throws: AgentNativeHookDecodeError.unsupportedEvent) {
          try AgentNativeHookDecoder.decode(
            runtime: runtime,
            nativeEvent: nativeEvent,
            payload: Data(
              """
              {"hook_event_name":"\(nativeEvent)","session_id":"s","cwd":"/tmp","tool_name":"Bash"}
              """.utf8
            )
          )
        }
      }
    }
  }

  @Test func onlyQoderReportsStopFailureAsTurnEnded() throws {
    let payload = Data(
      """
      {"hook_event_name":"StopFailure","session_id":"s","cwd":"/tmp","error_type":"unknown"}
      """.utf8
    )

    let qoder = try AgentNativeHookDecoder.decode(
      runtime: .qoder,
      nativeEvent: "StopFailure",
      payload: payload
    )
    #expect(qoder.event == .turnEnded)

    for runtime in [AgentNativeHookRuntime.copilot, .droid] {
      #expect(throws: AgentNativeHookDecodeError.unsupportedEvent) {
        try AgentNativeHookDecoder.decode(runtime: runtime, nativeEvent: "StopFailure", payload: payload)
      }
    }
  }

  @Test func s3bRuntimesFailClosedOnMismatchedAndInvalidPayloads() {
    for runtime in Self.s3bRuntimes {
      #expect(throws: AgentNativeHookDecodeError.eventMismatch) {
        try AgentNativeHookDecoder.decode(
          runtime: runtime,
          nativeEvent: "Stop",
          payload: Data(#"{"hook_event_name":"SessionEnd","session_id":"s","cwd":"/tmp"}"#.utf8)
        )
      }
      #expect(throws: AgentNativeHookDecodeError.malformedPayload) {
        try AgentNativeHookDecoder.decode(
          runtime: runtime,
          nativeEvent: "Stop",
          payload: Data(#"{"session_id":"s","cwd":"/tmp"}"#.utf8)
        )
      }
      // A relative cwd cannot be compared against the registered launch directory.
      #expect(throws: AgentNativeHookDecodeError.invalidField) {
        try AgentNativeHookDecoder.decode(
          runtime: runtime,
          nativeEvent: "Stop",
          payload: Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"relative/path"}"#.utf8)
        )
      }
      #expect(throws: AgentNativeHookDecodeError.unsupportedEvent) {
        try AgentNativeHookDecoder.decode(
          runtime: runtime,
          nativeEvent: "SubagentStop",
          payload: Data(#"{"hook_event_name":"SubagentStop","session_id":"s","cwd":"/tmp"}"#.utf8)
        )
      }
    }
  }

  @Test func runtimeRawValuesMatchProfileRuntimesSoObservationCanConvertThem() {
    for runtime in AgentNativeHookRuntime.allCases {
      #expect(
        AgentProfileRuntime(rawValue: runtime.rawValue) != nil,
        "\(runtime.rawValue) must round-trip into AgentProfileRuntime"
      )
    }
    #expect(AgentNativeHookRuntime.qoder.rawValue == "qodercli")
    #expect(AgentProfileRuntime.qoder.rawValue == "qodercli")
  }

  /// Runtimes disagree on how they report their working directory: Copilot echoes the shell's
  /// logical `/tmp/...` while Droid reports the kernel-resolved `/private/tmp/...`. Both name the
  /// same directory, so hook validation must compare resolved paths or the events are silently
  /// rejected (measured against Droid 0.202.0). Restored coverage for the fix in 9654f252.
  @Test func hookCWDComparisonResolvesSymlinkedTemporaryPaths() throws {
    let now = Date(timeIntervalSince1970: 100)
    let store = AgentObservationStore(bufferCapacity: 8, now: { now })
    let surfaceID = UUID()
    let capability = try #require(AgentRuntimeAdapterRegistry.profileAdapter(for: .droid)?.signalHooks)

    // Resolution only applies to paths that exist, which a real launch directory always does.
    let name = "prowl-cwd-probe-\(UUID().uuidString)"
    let logical = "/tmp/\(name)"
    let resolved = "/private/tmp/\(name)"
    try FileManager.default.createDirectory(atPath: logical, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: logical) }

    let registration = AgentHookLaunchRegistration(
      token: "token-droid",
      runtime: capability.runtime,
      // The launch registers the logical path Prowl tracks for the worktree.
      launchCWD: URL(filePath: logical, directoryHint: .isDirectory),
      nativeEvents: capability.nativeEvents,
      coveredEvents: capability.coveredEvents,
      forwardingRecord: nil
    )
    _ = store.registerManagedHook(registration, surfaceID: surfaceID)
    let generation = AgentProcessGeneration(pid: 900, startedAt: now)
    _ = store.updateEvidenceEpoch(surfaceID: surfaceID, processGeneration: generation, sessionID: nil)

    // The hook reports the same directory through its resolved path.
    let accepted = store.recordManagedHook(
      AgentNativeHookInput(
        runtime: .droid,
        token: registration.token,
        signal: AgentNativeHookSignal(
          event: .turnEnded, nativeEvent: "Stop", cwd: resolved, sessionID: "session-1")
      ),
      callerAncestry: [generation],
      surfaceID: surfaceID
    )
    guard case .accepted = accepted else {
      Issue.record("resolved-equivalent cwd must be accepted, got \(accepted)")
      return
    }

    // A genuinely different directory still fails closed.
    let elsewhere = store.recordManagedHook(
      AgentNativeHookInput(
        runtime: .droid,
        token: registration.token,
        signal: AgentNativeHookSignal(
          event: .turnEnded, nativeEvent: "Stop",
          cwd: "/private/tmp/prowl-definitely-not-the-launch-directory", sessionID: "session-1")
      ),
      callerAncestry: [generation],
      surfaceID: surfaceID
    )
    #expect(elsewhere == .rejected)
  }

  /// The observation store must accept a real launch/registration cycle for each S3b runtime,
  /// not just Claude and Codex. This is the deterministic counterpart to the live gate.
  @Test func eachS3bRuntimeVerifiesItsChannelThroughTheObservationStore() throws {
    let now = Date(timeIntervalSince1970: 100)
    let formatter = ISO8601DateFormatter()

    for profileRuntime in [AgentProfileRuntime.copilot, .droid, .qoder] {
      let capability = try #require(
        AgentRuntimeAdapterRegistry.profileAdapter(for: profileRuntime)?.signalHooks
      )
      let store = AgentObservationStore(bufferCapacity: 8, now: { now })
      let surfaceID = UUID()
      let registration = AgentHookLaunchRegistration(
        token: "token-\(capability.runtime.rawValue)",
        runtime: capability.runtime,
        launchCWD: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
        nativeEvents: capability.nativeEvents,
        coveredEvents: capability.coveredEvents,
        forwardingRecord: nil
      )
      _ = store.registerManagedHook(registration, surfaceID: surfaceID)
      let generation = AgentProcessGeneration(pid: 900, startedAt: now)
      _ = store.updateEvidenceEpoch(surfaceID: surfaceID, processGeneration: generation, sessionID: nil)

      func send(_ nativeEvent: String, _ event: AgentSignalEvent) -> ManagedHookRecordResult {
        store.recordManagedHook(
          AgentNativeHookInput(
            runtime: capability.runtime,
            token: registration.token,
            signal: AgentNativeHookSignal(
              event: event,
              nativeEvent: nativeEvent,
              cwd: "/tmp/project",
              sessionID: "session-1"
            )
          ),
          callerAncestry: [generation],
          surfaceID: surfaceID
        )
      }

      guard case .accepted = send("SessionStart", .sessionStart) else {
        Issue.record("\(capability.runtime.rawValue) did not accept SessionStart")
        continue
      }
      guard case .accepted(let stop, _) = send("Stop", .turnEnded) else {
        Issue.record("\(capability.runtime.rawValue) did not accept Stop")
        continue
      }
      #expect(stop.source == .hook(runtime: profileRuntime, event: "Stop"))
      #expect(stop.source.payloadName == "hook_\(profileRuntime.rawValue)")

      let channel = try #require(
        store.signalsPayload(surfaceID: surfaceID, formatter: formatter, includeDiagnosticLast: true)
          .channels.first
      )
      #expect(channel.state == .verifiedLive)
      #expect(channel.events == [.needsInput, .sessionEnd, .sessionStart, .turnEnded])

      // A mid-session event from a different session is not allowed to take over.
      let strayStop = store.recordManagedHook(
        AgentNativeHookInput(
          runtime: capability.runtime,
          token: registration.token,
          signal: AgentNativeHookSignal(
            event: .turnEnded,
            nativeEvent: "Stop",
            cwd: "/tmp/project",
            sessionID: "session-2"
          )
        ),
        callerAncestry: [generation],
        surfaceID: surfaceID
      )
      #expect(strayStop == .rejected)
    }
  }

  /// A genuine new session announces itself with `SessionStart` and must be adopted, exactly as
  /// Claude's is. Otherwise starting a fresh session in the same pane (Droid's `/new`) would
  /// leave the channel permanently unable to accept its own agent's events.
  @Test func s3bRuntimesAdoptANewSessionAnnouncedBySessionStart() throws {
    let now = Date(timeIntervalSince1970: 100)

    for profileRuntime in [AgentProfileRuntime.copilot, .droid, .qoder] {
      let capability = try #require(
        AgentRuntimeAdapterRegistry.profileAdapter(for: profileRuntime)?.signalHooks
      )
      let store = AgentObservationStore(bufferCapacity: 8, now: { now })
      let surfaceID = UUID()
      let registration = AgentHookLaunchRegistration(
        token: "token-\(capability.runtime.rawValue)",
        runtime: capability.runtime,
        launchCWD: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
        nativeEvents: capability.nativeEvents,
        coveredEvents: capability.coveredEvents,
        forwardingRecord: nil
      )
      _ = store.registerManagedHook(registration, surfaceID: surfaceID)
      let generation = AgentProcessGeneration(pid: 900, startedAt: now)
      _ = store.updateEvidenceEpoch(surfaceID: surfaceID, processGeneration: generation, sessionID: nil)

      func send(_ nativeEvent: String, _ event: AgentSignalEvent, _ session: String) -> ManagedHookRecordResult {
        store.recordManagedHook(
          AgentNativeHookInput(
            runtime: capability.runtime,
            token: registration.token,
            signal: AgentNativeHookSignal(
              event: event,
              nativeEvent: nativeEvent,
              cwd: "/tmp/project",
              sessionID: session
            )
          ),
          callerAncestry: [generation],
          surfaceID: surfaceID
        )
      }

      _ = send("SessionStart", .sessionStart, "session-1")
      guard case .accepted = send("SessionStart", .sessionStart, "session-2") else {
        Issue.record("\(capability.runtime.rawValue) must adopt a new session via SessionStart")
        continue
      }
      guard case .accepted = send("Stop", .turnEnded, "session-2") else {
        Issue.record("\(capability.runtime.rawValue) must accept events from the adopted session")
        continue
      }
    }
  }
}
