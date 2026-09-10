import Foundation
import JSONSchema
import ProwlCLIContracts
import ProwlCLIShared
import XCTest

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

final class ProwlCLIIntegrationTests: XCTestCase {
  private var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  /// Backstop cleanup for mock-server socket files. `MockSocketServer.stop()`
  /// (run via `defer`) covers the normal and throwing paths, but a test process
  /// killed mid-run (timeout, Ctrl-C) skips both `defer` and `deinit` and leaks
  /// the bound socket. Sweep any leftover `prowl-cli-*` from the socket
  /// directory after each test so they cannot accumulate. Matched by prefix
  /// only (no `.sock` suffix), so a truncated name would still be caught.
  override func tearDownWithError() throws {
    let dir = Self.socketDirectory
    for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    where name.hasPrefix("prowl-cli-") {
      unlink((dir as NSString).appendingPathComponent(name))
    }
    try super.tearDownWithError()
  }

  func testHelpAndVersionSmoke() throws {
    let version = try runProwl(args: ["--version"])
    XCTAssertEqual(version.exitCode, 0)
    XCTAssertTrue(version.stdout.contains(ProwlVersion.current))

    let help = try runProwl(args: ["--help"])
    XCTAssertEqual(help.exitCode, 0)
    XCTAssertTrue(help.stdout.contains("USAGE:"))
    XCTAssertTrue(help.stdout.contains("create"))
    XCTAssertTrue(help.stdout.contains("close"))
    XCTAssertTrue(help.stdout.contains("skills"))
    XCTAssertTrue(
      help.stdout.contains("prowl skills install"),
      "Root help should tell users and agents how to link the bundled skills"
    )
  }

  func testNativeHookBridgeIsHiddenSilentAndFailOpenWithoutListener() throws {
    let help = try runProwl(args: ["agents", "--help"])
    XCTAssertEqual(help.exitCode, 0)
    XCTAssertFalse(help.stdout.contains("_hook"))

    let payload = Data(
      #"{"hook_event_name":"Stop","session_id":"session-1","cwd":"/tmp/project"}"#.utf8
    )
    let result = try runProwl(
      args: ["agents", "_hook", "claude", "Stop"],
      environment: [
        AgentNativeHookInput.tokenEnvironmentKey: "token-1",
        ProwlSocket.environmentKey: temporarySocketPath(suffix: "missing-hook-listener"),
      ],
      stdinData: payload
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout, "")
    XCTAssertEqual(result.stderr, "")
  }

  func testNativeHookBridgeEnforcesATotalDeadlineAgainstDripResponse() throws {
    let socketPath = temporarySocketPath(suffix: "hook-drip-deadline")
    let server = try MockSocketServer(
      socketPath: socketPath,
      responseData: Data("abcde".utf8),
      responseByteDelayMicroseconds: 200_000
    )
    try server.start()
    defer { server.stop() }
    let payload = Data(
      #"{"hook_event_name":"Stop","session_id":"session-1","cwd":"/tmp/project"}"#.utf8
    )
    let clock = ContinuousClock()
    let start = clock.now

    let result = try runProwl(
      args: ["agents", "_hook", "claude", "Stop"],
      environment: [
        AgentNativeHookInput.tokenEnvironmentKey: "token-1",
        ProwlSocket.environmentKey: socketPath,
      ],
      stdinData: payload
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout, "")
    XCTAssertEqual(result.stderr, "")
    XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(700))
  }

  func testNativeHookBridgeSurvivesClosedPeerWithDefaultSIGPIPEDisposition() throws {
    let socketPath = temporarySocketPath(suffix: "hook-sigpipe")
    let server = try MockSocketServer(
      socketPath: socketPath,
      responseData: Data(),
      closesAfterRequestLength: true
    )
    try server.start()
    defer { server.stop() }
    let payload = try JSONSerialization.data(
      withJSONObject: [
        "hook_event_name": "Stop",
        "session_id": "session-1",
        "cwd": "/tmp/project",
        "reason": String(repeating: "x", count: AgentSignalInput.maximumDetailBytes),
      ]
    )

    let result = try runProwlWithDefaultSIGPIPE(
      args: ["agents", "_hook", "claude", "Stop"],
      environment: [
        AgentNativeHookInput.tokenEnvironmentKey: "token-1",
        ProwlSocket.environmentKey: socketPath,
      ],
      stdinData: payload
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout, "")
    XCTAssertEqual(result.stderr, "")
  }

  func testCodexHookForwardsExactPayloadOnTransportLossAndScrubsInternalEnvironment() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "prowl-hook-forward-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: root.path
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("notifier.py")
    let output = root.appendingPathComponent("result.json")
    try """
    import json, os, sys
    with open(os.environ["PROWL_FORWARD_TEST_OUTPUT"], "w") as handle:
        json.dump({
            "argv": sys.argv[1:],
            "token": os.environ.get("PROWL_AGENT_HOOK_TOKEN"),
            "record": os.environ.get("PROWL_AGENT_HOOK_FORWARD_RECORD")
        }, handle, ensure_ascii=False)
    raise SystemExit(7)
    """.write(to: script, atomically: true, encoding: .utf8)
    let record = root.appendingPathComponent("record.json")
    let notifierArgv = ["/usr/bin/python3", script.path, "space value", "", "秘密-like"]
    try JSONSerialization.data(withJSONObject: notifierArgv).write(to: record, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
    let payload =
      #"{"type":"agent-turn-complete","thread-id":"thread-1","turn-id":"turn-1","cwd":"/tmp/project","last-assistant-message":"excluded"}"#

    let result = try runProwl(
      args: ["agents", "_hook", "codex", "agent-turn-complete", payload],
      environment: [
        AgentNativeHookInput.tokenEnvironmentKey: "invalid-but-forwarding-independent",
        AgentNativeHookInput.forwardRecordEnvironmentKey: record.path,
        ProwlSocket.environmentKey: temporarySocketPath(suffix: "missing-forward-listener"),
        "PROWL_FORWARD_TEST_OUTPUT": output.path,
      ]
    )

    XCTAssertEqual(result.exitCode, 7)
    XCTAssertEqual(result.stdout, "")
    XCTAssertEqual(result.stderr, "")
    let forwarded = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]
    )
    XCTAssertEqual(forwarded["argv"] as? [String], ["space value", "", "秘密-like", payload])
    XCTAssertTrue(forwarded["token"] is NSNull)
    XCTAssertTrue(forwarded["record"] is NSNull)
  }

  func testLegacyLifecycleHelpIsMarkedDeprecated() throws {
    let tabHelp = try runProwl(args: ["tab", "--help"])
    XCTAssertEqual(tabHelp.exitCode, 0)
    XCTAssertTrue(tabHelp.stdout.contains("[Deprecated]"))

    let paneHelp = try runProwl(args: ["pane", "--help"])
    XCTAssertEqual(paneHelp.exitCode, 0)
    XCTAssertTrue(paneHelp.stdout.contains("[Deprecated]"))
  }

  func testListReturnsAppNotRunningWhenSocketUnavailable() throws {
    let socketPath = temporarySocketPath(suffix: "app-not-running")
    let result = try runProwl(
      args: ["list", "--json"],
      environment: [ProwlSocket.environmentKey: socketPath]
    )

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.appNotRunning)
  }

  func testListReportsSocketPermissionDeniedWhenSocketCannotBeOpened() throws {
    let socketPath = temporarySocketPath(suffix: "permission-denied")
    let socket = PermissionDeniedSocket(socketPath: socketPath)
    try socket.start()
    defer { socket.stop() }

    let result = try runProwl(
      args: ["list", "--json"],
      environment: [ProwlSocket.environmentKey: socketPath]
    )

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.socketPermissionDenied)
    let message = try XCTUnwrap(error["message"] as? String)
    XCTAssertTrue(message.contains("EACCES"), "Message should include errno name: \(message)")
    XCTAssertTrue(
      message.localizedCaseInsensitiveContains("sandbox"), "Message should guide agent recovery: \(message)")
  }

  func testListReportsTransportFailedWhenSocketPathIsNotASocket() throws {
    let socketPath = temporarySocketPath(suffix: "not-a-socket")
    XCTAssertTrue(FileManager.default.createFile(atPath: socketPath, contents: Data()))
    defer { unlink(socketPath) }

    let result = try runProwl(
      args: ["list", "--json"],
      environment: [ProwlSocket.environmentKey: socketPath]
    )

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.transportFailed)
    let message = try XCTUnwrap(error["message"] as? String)
    XCTAssertTrue(message.contains("ENOTSOCK"), "Message should include errno name: \(message)")
  }

  func testListReportsTransportFailedWhenSocketPathIsTooLong() throws {
    let socketPath = (Self.socketDirectory as NSString)
      .appendingPathComponent("prowl-cli-\(String(repeating: "x", count: 120)).sock")

    let result = try runProwl(
      args: ["list", "--json"],
      environment: [ProwlSocket.environmentKey: socketPath]
    )

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.transportFailed)
    let message = try XCTUnwrap(error["message"] as? String)
    XCTAssertTrue(
      message.localizedCaseInsensitiveContains("too long"), "Message should identify path length: \(message)")
  }

  func testAgentsCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "agents")
    let response = try CommandResponse(
      ok: true,
      command: "agents",
      schemaVersion: "prowl.cli.agents.v1",
      data: RawJSON(encoding: AgentsResponseData(count: 0, agents: []))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["agents", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .agents = envelope.command {
      // expected
    } else {
      XCTFail("Expected agents command envelope")
    }

    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, true)
    XCTAssertEqual(payload["command"] as? String, "agents")
  }

  func testAgentsSignalRoundTripsOverSocketInTextMode() throws {
    let socketPath = temporarySocketPath(suffix: "agents-signal-text")
    let paneID = "6E1A2A10-D99F-4E3F-920C-D93AA3C05764"
    let response = try CommandResponse(
      ok: true,
      command: "agents.signal",
      schemaVersion: "prowl.cli.agents.signal.v1",
      data: RawJSON(
        encoding: AgentSignalCommandPayload(
          pane: AgentSignalPanePayload(id: paneID, worktreeID: "/Projects/App"),
          signal: AgentSignalPayload(
            event: .turnEnded,
            progress: nil,
            source: "cooperative_cli",
            confidence: "exact",
            binding: .current,
            timestamp: "2026-08-22T12:00:00.000Z",
            sessionID: "session-1",
            detail: "Review complete",
            claimedOrigin: "manual-review"
          )
        ))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: [
        "agents", "signal", "turn-ended",
        "--origin", "manual-review",
        "--session", "session-1",
        "--detail", "Review complete",
        "--no-color",
      ]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout, "Signaled turn-ended for pane \(paneID).\n")
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    guard case .agentsSignal(let input) = envelope.command else {
      return XCTFail("Expected agents.signal command envelope")
    }
    XCTAssertEqual(input.event, .turnEnded)
    XCTAssertEqual(input.origin, "manual-review")
    XCTAssertEqual(input.sessionID, "session-1")
    XCTAssertEqual(input.detail, "Review complete")
  }

  func testAgentsSignalPreservesSchemaValidatedJSONResponse() throws {
    let socketPath = temporarySocketPath(suffix: "agents-signal-json")
    let response = try CommandResponse(
      ok: true,
      command: "agents.signal",
      schemaVersion: "prowl.cli.agents.signal.v1",
      data: RawJSON(
        encoding: AgentSignalCommandPayload(
          pane: AgentSignalPanePayload(
            id: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764",
            worktreeID: "/Projects/App"
          ),
          signal: AgentSignalPayload(
            event: .progress,
            progress: 75,
            source: "cooperative_cli",
            confidence: "exact",
            binding: .current,
            timestamp: "2026-08-22T12:00:00.000Z",
            sessionID: nil,
            detail: nil,
            claimedOrigin: nil
          )
        ))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["agents", "signal", "progress", "--progress", "75", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let request = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    guard case .agentsSignal(let input) = request.command else {
      return XCTFail("Expected agents.signal command envelope")
    }
    XCTAssertEqual(input.progress, 75)
    let rendered = try jsonObject(from: result.stdout)
    XCTAssertEqual(rendered["command"] as? String, "agents.signal")
    XCTAssertEqual(rendered["schema_version"] as? String, "prowl.cli.agents.signal.v1")
  }

  func testDispatchRoundTripsOverSocketWithStdinPrompt() throws {
    let socketPath = temporarySocketPath(suffix: "dispatch")
    let response = try CommandResponse(
      ok: true,
      command: "agents.dispatch",
      schemaVersion: "prowl.cli.agents.dispatch.v1",
      data: RawJSON(
        encoding: AgentDispatchCommandPayload(
          target: makeTabTarget(),
          dispatch: DispatchPendingRecord(id: "dispatch-2", createdAt: "2026-08-29T04:00:00.000Z")
        )
      )
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["agents", "dispatch", "p7", "--prompt", "-", "--json"],
      stdinData: Data("Round two.\nRe-review the diff against main.\n".utf8)
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    guard case .agentsDispatch(let input) = envelope.command else {
      return XCTFail("Expected agents.dispatch command envelope")
    }
    XCTAssertEqual(input.pane, "p7")
    XCTAssertEqual(input.prompt, "Round two.\nRe-review the diff against main.")
    let rendered = try jsonObject(from: result.stdout)
    let data = try XCTUnwrap(rendered["data"] as? [String: Any])
    let dispatch = try XCTUnwrap(data["dispatch"] as? [String: Any])
    XCTAssertEqual(dispatch["id"] as? String, "dispatch-2")
    XCTAssertEqual(dispatch["state"] as? String, "pending")
  }

  func testDispatchRefusalRendersGovernedDetails() throws {
    let socketPath = temporarySocketPath(suffix: "dispatch-pending")
    let response = CommandResponse(
      ok: false,
      command: "agents.dispatch",
      schemaVersion: "prowl.cli.agents.dispatch.v1",
      error: CommandError(
        code: CLIErrorCode.dispatchPending,
        message: "Pending.",
        details: try RawJSON(
          encoding: AgentDispatchErrorDetails(
            target: makeTabTarget(),
            record: .pending(DispatchPendingRecord(id: "dispatch-1", createdAt: "2026-08-29T04:00:00.000Z"))
          ))
      )
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["agents", "dispatch", "p7", "--prompt", "-"],
      stdinData: Data("Round two.\n".utf8)
    )

    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertTrue(result.stderr.contains("error [DISPATCH_PENDING]: Pending."))
    XCTAssertTrue(result.stderr.contains("dispatch: dispatch-1 (pending)"))
  }

  func testDispatchCompleteRoundTripsOverSocketWithoutLaunchContext() throws {
    let socketPath = temporarySocketPath(suffix: "dispatch-complete-no-env")
    let response = try CommandResponse(
      ok: true,
      command: "agents.dispatch-complete",
      schemaVersion: "prowl.cli.agents.dispatch-complete.v1",
      data: RawJSON(
        encoding: DispatchCompleteCommandPayload(
          target: makeTabTarget(),
          receipt: DispatchCompletedRecord(
            id: "dispatch-complete-2",
            outcome: .failed,
            summary: "Blocked",
            createdAt: "2026-08-29T04:00:00.000Z",
            completedAt: "2026-08-29T04:01:00.000Z"
          ),
          replayed: false
        )
      )
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["agents", "dispatch-complete", "--outcome", "failed", "--summary", "Blocked", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    guard case .agentsDispatchComplete(let input) = envelope.command else {
      return XCTFail("Expected agents.dispatch-complete command envelope")
    }
    XCTAssertNil(input.dispatchID)
    XCTAssertEqual(input.outcome, .failed)
  }

  func testDispatchCompleteRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "dispatch-complete")
    let response = try CommandResponse(
      ok: true,
      command: "agents.dispatch-complete",
      schemaVersion: "prowl.cli.agents.dispatch-complete.v1",
      data: RawJSON(
        encoding: DispatchCompleteCommandPayload(
          target: makeTabTarget(),
          receipt: DispatchCompletedRecord(
            id: "dispatch-complete-1",
            outcome: .succeeded,
            summary: "Review complete",
            createdAt: "2026-08-23T04:00:00.000Z",
            completedAt: "2026-08-23T04:01:00.000Z"
          ),
          replayed: false
        )
      )
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: [
        "agents", "dispatch-complete", "--outcome", "succeeded", "--summary",
        "Review complete", "--json",
      ],
      environment: [DispatchCompleteInput.environmentKey: "dispatch-complete-1"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    guard case .agentsDispatchComplete(let input) = envelope.command else {
      return XCTFail("Expected agents.dispatch-complete command envelope")
    }
    XCTAssertEqual(input.dispatchID, "dispatch-complete-1")
    XCTAssertEqual(input.outcome, .succeeded)
    XCTAssertEqual(input.summary, "Review complete")
  }

  func testDispatchAbandonRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "dispatch-abandon")
    let response = try CommandResponse(
      ok: true,
      command: "agents.dispatch-abandon",
      schemaVersion: "prowl.cli.agents.dispatch-abandon.v1",
      data: RawJSON(
        encoding: DispatchAbandonCommandPayload(
          target: makeTabTarget(),
          record: DispatchAbandonedRecord(
            id: "dispatch-abandon-1",
            createdAt: "2026-08-23T04:00:00.000Z",
            abandonedAt: "2026-08-23T04:01:00.000Z",
            reason: "Superseded"
          ),
          replayed: false
        )
      )
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: [
        "agents", "dispatch-abandon", "--dispatch", "dispatch-abandon-1", "--reason",
        "Superseded", "--json",
      ]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    guard case .agentsDispatchAbandon(let input) = envelope.command else {
      return XCTFail("Expected agents.dispatch-abandon command envelope")
    }
    XCTAssertEqual(input.dispatchID, "dispatch-abandon-1")
    XCTAssertEqual(input.reason, "Superseded")
  }

  func testDispatchWaitRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "dispatch-wait")
    let response = try CommandResponse(
      ok: true,
      command: "agents.wait",
      schemaVersion: "prowl.cli.agents.wait.v1",
      data: RawJSON(
        encoding: AgentWaitCommandPayload.dispatch(
          AgentDispatchWaitPayload(
            waitedMilliseconds: 125,
            target: makeTabTarget(),
            receipt: DispatchCompletedRecord(
              id: "dispatch-wait-1",
              outcome: .succeeded,
              summary: "Done",
              createdAt: "2026-08-23T04:00:00.000Z",
              completedAt: "2026-08-23T04:01:00.000Z"
            ),
            signals: AgentSignalsPayload(channels: [], last: nil, lastBinding: nil)
          )
        )
      )
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["agents", "wait", "--dispatch", "dispatch-wait-1", "--timeout", "10", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    guard case .agentsWait(let input) = envelope.command else {
      return XCTFail("Expected agents.wait command envelope")
    }
    XCTAssertEqual(input.mode, .dispatch)
    XCTAssertEqual(input.dispatchID, "dispatch-wait-1")
  }

  func testConditionWaitRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "condition-wait")
    let response = try CommandResponse(
      ok: true,
      command: "agents.wait",
      schemaVersion: "prowl.cli.agents.wait.v1",
      data: RawJSON(
        encoding: AgentWaitCommandPayload.condition(
          AgentConditionWaitPayload(
            condition: .blocked,
            waitedMilliseconds: 200,
            target: makeTabTarget(),
            observation: AgentWaitObservation(
              status: .blocked,
              rawState: "blocked",
              source: "cooperative_cli",
              confidence: "exact",
              timestamp: "2026-08-23T04:01:00.000Z",
              revision: 2
            ),
            signals: AgentSignalsPayload(channels: [], last: nil, lastBinding: nil)
          )
        )
      )
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: [
        "agents", "wait", "pane-123", "--until", "blocked", "--min-confidence", "exact",
        "--timeout", "10", "--json",
      ]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    guard case .agentsWait(let input) = envelope.command else {
      return XCTFail("Expected agents.wait command envelope")
    }
    XCTAssertEqual(input.mode, .condition)
    XCTAssertEqual(input.pane, "pane-123")
    XCTAssertEqual(input.condition, .blocked)
    XCTAssertEqual(input.minimumConfidence, .exact)
  }

  func testAgentsPayloadDetectionReasonRemainsBackwardCompatible() throws {
    let modernData = try JSONEncoder().encode(
      AgentsResponseData(
        count: 1,
        agents: [
          makeAgentResponse(
            id: "modern-pane",
            name: "codex",
            status: "blocked",
            projectName: "Prowl",
            branch: "main",
            tabTitle: "Modern",
            detectionReason: "codex.directoryTrust"
          )
        ]
      )
    )
    let modernPayload = try JSONDecoder().decode(AgentsCommandPayload.self, from: modernData)
    XCTAssertEqual(modernPayload.agents.first?.detectionReason, "codex.directoryTrust")

    let legacyData = try JSONEncoder().encode(
      AgentsResponseData(
        count: 1,
        agents: [
          makeAgentResponse(
            id: "legacy-pane",
            name: "claude",
            status: "idle",
            projectName: "Prowl",
            branch: "main",
            tabTitle: "Legacy"
          )
        ]
      )
    )
    let legacyPayload = try JSONDecoder().decode(AgentsCommandPayload.self, from: legacyData)
    XCTAssertNil(legacyPayload.agents.first?.detectionReason)
  }

  func testJSONModePreservesEscapedControlCharactersFromAppResponse() throws {
    let socketPath = temporarySocketPath(suffix: "json-control")
    let responseJSON = [
      #"{"ok":true,"command":"read","schema_version":"prowl.cli.read.v1","data":{"#,
      #""target":{"#,
      #""worktree":{"id":"wt-1","name":"main","path":"/Projects/App","root_path":"/Projects/App","kind":"git"},"#,
      #""tab":{"id":"tab-1","title":"Tab\u0007Title","selected":true},"#,
      #""pane":{"id":"pane-1","title":"zsh\u001b[31m","cwd":"/Projects/App","focused":true}"#,
      #"},"#,
      #""mode":"last","last":80,"source":"scrollback","truncated":false,"#,
      #""line_count":1,"text":"alpha\u001b[31mbeta\u0000end"}}"#,
    ].joined()
    let responseData = try XCTUnwrap(responseJSON.data(using: .utf8))

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      responseData: responseData,
      args: ["read", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout, "\(responseJSON)\n")
    assertNoRawJSONControlCharacters(in: result.stdout)

    let payload = try jsonObject(from: result.stdout)
    let data = try XCTUnwrap(payload["data"] as? [String: Any])
    XCTAssertEqual(data["text"] as? String, "alpha\u{1B}[31mbeta\u{0}end")

    let target = try XCTUnwrap(data["target"] as? [String: Any])
    let tab = try XCTUnwrap(target["tab"] as? [String: Any])
    let pane = try XCTUnwrap(target["pane"] as? [String: Any])
    XCTAssertEqual(tab["title"] as? String, "Tab\u{7}Title")
    XCTAssertEqual(pane["title"] as? String, "zsh\u{1B}[31m")
  }

  func testOpenCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "open")
    let response = try CommandResponse(
      ok: true,
      command: "open",
      schemaVersion: "prowl.cli.open.v1",
      data: RawJSON(
        encoding: OpenResponseData(
          invocation: "open-subcommand",
          requestedPath: repoRoot.path,
          resolvedPath: repoRoot.path,
          resolution: "exact-root",
          appLaunched: false,
          broughtToFront: true
        ))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["open", ".", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .open(let input) = envelope.command {
      let openedPath = try XCTUnwrap(input.path)
      XCTAssertEqual(input.invocation, "open-subcommand")
      XCTAssertEqual(
        URL(fileURLWithPath: openedPath).resolvingSymlinksInPath().path,
        repoRoot.resolvingSymlinksInPath().path
      )
    } else {
      XCTFail("Expected open command envelope")
    }

    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, true)
    XCTAssertEqual(payload["command"] as? String, "open")
  }

  func testOpenCommandTextSuccessIsSilent() throws {
    let socketPath = temporarySocketPath(suffix: "open-text")
    let response = try CommandResponse(
      ok: true,
      command: "open",
      schemaVersion: "prowl.cli.open.v1",
      data: RawJSON(
        encoding: OpenResponseData(
          invocation: "implicit-open",
          requestedPath: repoRoot.path,
          resolvedPath: repoRoot.path,
          resolution: "exact-root",
          appLaunched: false,
          broughtToFront: true
        ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["."]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout, "")
    XCTAssertEqual(result.stderr, "")
  }

  func testFocusCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "focus")
    let response = CommandResponse(
      ok: true,
      command: "focus",
      schemaVersion: "prowl.cli.focus.v1"
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["focus", "--pane", "pane-123", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .focus(let input) = envelope.command {
      XCTAssertEqual(input.selector, .pane("pane-123"))
    } else {
      XCTFail("Expected focus command envelope")
    }

    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, true)
    XCTAssertEqual(payload["command"] as? String, "focus")
  }

  func testFocusCommandWithoutSelectorSendsCurrentTarget() throws {
    let socketPath = temporarySocketPath(suffix: "focus-current")
    let response = CommandResponse(
      ok: true,
      command: "focus",
      schemaVersion: "prowl.cli.focus.v1"
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["focus", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .focus(let input) = envelope.command {
      XCTAssertEqual(input.selector, .none)
    } else {
      XCTFail("Expected focus command envelope")
    }
  }

  func testReadPositionalPrefixedPaneHandleRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "read-pane-handle")
    let response = CommandResponse(
      ok: true,
      command: "read",
      schemaVersion: "prowl.cli.read.v1"
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["read", "p12", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .read(let input) = envelope.command {
      XCTAssertEqual(input.selector, .auto("p12"))
    } else {
      XCTFail("Expected read command envelope")
    }
  }

  func testCreateTabCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "create-tab")
    let response = try CommandResponse(
      ok: true,
      command: "create",
      schemaVersion: "prowl.cli.create.v1",
      data: RawJSON(encoding: makeLifecyclePayload(resource: .tab))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["create", "tab", "App", "--path", "/Projects/App", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .create(let input) = envelope.command {
      XCTAssertEqual(input.resource, .tab)
      XCTAssertEqual(input.selector, .worktree("App"))
      XCTAssertEqual(input.path, "/Projects/App")
    } else {
      XCTFail("Expected create command envelope")
    }
  }

  func testCreatePaneCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "create-pane")
    let response = try CommandResponse(
      ok: true,
      command: "create",
      schemaVersion: "prowl.cli.create.v1",
      data: RawJSON(
        encoding: makeLifecyclePayload(
          resource: .pane,
          anchor: makeTabTarget(paneID: "anchor-pane"),
          direction: .upward
        )
      )
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["create", "pane", "p12", "--direction", "up", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .create(let input) = envelope.command {
      XCTAssertEqual(input.resource, .pane)
      XCTAssertEqual(input.selector, .pane("p12"))
      XCTAssertEqual(input.direction, .upward)
      XCTAssertNil(input.path)
    } else {
      XCTFail("Expected create command envelope")
    }
  }

  func testCreateTabProfileRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "create-tab-profile")
    let launch = LifecycleCommandLaunch(
      profileID: UUID().uuidString,
      profileName: "Reviewer",
      agent: "claude"
    )
    let response = try CommandResponse(
      ok: true,
      command: "create",
      schemaVersion: "prowl.cli.create.v1",
      data: RawJSON(encoding: makeLifecyclePayload(resource: .tab, launch: launch))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["create", "tab", "App", "--profile", launch.profileID, "--background", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .create(let input) = envelope.command {
      XCTAssertEqual(input.launch, CreateLaunchInput(profile: launch.profileID))
      XCTAssertTrue(input.background)
    } else {
      XCTFail("Expected create command envelope")
    }
  }

  func testCreateWarningStaysInJSONAndRendersExactlyOnceToTextStderr() throws {
    let launch = LifecycleCommandLaunch(
      profileID: UUID().uuidString,
      profileName: "Codex",
      agent: "codex"
    )
    let warning = LifecycleCommandWarning(
      code: .managedHookDegraded,
      runtime: "codex",
      message: "Notifier resolver unavailable."
    )
    let response = try CommandResponse(
      ok: true,
      command: "create",
      schemaVersion: "prowl.cli.create.v1",
      data: RawJSON(
        encoding: makeLifecyclePayload(resource: .tab, launch: launch, warnings: [warning])
      )
    )

    let textSocket = temporarySocketPath(suffix: "create-warning-text")
    let (_, text) = try runWithMockServer(
      socketPath: textSocket,
      response: response,
      args: ["create", "tab", "App", "--profile", launch.profileID]
    )
    XCTAssertEqual(text.exitCode, 0)
    XCTAssertEqual(
      text.stderr,
      "warning: [managed_hook_degraded] codex: Notifier resolver unavailable.\n"
    )
    XCTAssertFalse(text.stdout.contains("managed_hook_degraded"))

    let jsonSocket = temporarySocketPath(suffix: "create-warning-json")
    let (_, json) = try runWithMockServer(
      socketPath: jsonSocket,
      response: response,
      args: ["create", "tab", "App", "--profile", launch.profileID, "--json"]
    )
    XCTAssertEqual(json.exitCode, 0)
    XCTAssertEqual(json.stderr, "")
    XCTAssertTrue(json.stdout.contains("managed_hook_degraded"))
  }

  func testCreateProfileFailsClosedWhenTheAppOmitsLaunchMetadata() throws {
    let socketPath = temporarySocketPath(suffix: "create-profile-version-skew")
    let response = try CommandResponse(
      ok: true,
      command: "create",
      schemaVersion: "prowl.cli.create.v1",
      data: RawJSON(encoding: makeLifecyclePayload(resource: .tab))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["create", "tab", "App", "--profile", "Reviewer", "--json"]
    )

    XCTAssertNotEqual(result.exitCode, 0)
    let output = try jsonObject(from: result.stdout)
    let error = try XCTUnwrap(output["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.createFailed)
    XCTAssertTrue((error["message"] as? String)?.contains("ordinary shell may have been created") == true)
    XCTAssertTrue((error["message"] as? String)?.contains("prowl list") == true)
  }

  func testPromptedCreateFailsClosedWhenTheAppOmitsDispatchMetadata() throws {
    let socketPath = temporarySocketPath(suffix: "create-prompt-dispatch-version-skew")
    let response = try CommandResponse(
      ok: true,
      command: "create",
      schemaVersion: "prowl.cli.create.v1",
      data: RawJSON(
        encoding: makeLifecyclePayload(
          resource: .tab,
          launch: LifecycleCommandLaunch(
            profileID: UUID().uuidString,
            profileName: "Reviewer",
            agent: "claude"
          )
        )
      )
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["create", "tab", "App", "--profile", "Reviewer", "--prompt", "-", "--json"],
      stdinData: Data("Review this change.\n".utf8)
    )

    XCTAssertNotEqual(result.exitCode, 0)
    let output = try jsonObject(from: result.stdout)
    let error = try XCTUnwrap(output["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.createFailed)
    XCTAssertTrue((error["message"] as? String)?.contains("dispatch receipt") == true)
  }

  func testCreatePaneProfilePromptRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "create-pane-profile")
    let launch = LifecycleCommandLaunch(
      profileID: UUID().uuidString,
      profileName: "Reviewer",
      agent: "claude"
    )
    let response = try CommandResponse(
      ok: true,
      command: "create",
      schemaVersion: "prowl.cli.create.v1",
      data: RawJSON(
        encoding: makeLifecyclePayload(
          resource: .pane,
          anchor: makeTabTarget(paneID: "anchor-pane"),
          direction: .right,
          launch: launch,
          dispatch: DispatchPendingRecord(
            id: "dispatch-create-pane",
            createdAt: "2026-08-23T04:00:00.000Z"
          )
        )
      )
    )
    let prompt = "Review the current diff and report only actionable findings.\n"

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: [
        "create", "pane", "p12", "--direction", "right", "--profile", "Reviewer",
        "--prompt", "-", "--background", "--json",
      ],
      stdinData: Data(prompt.utf8)
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .create(let input) = envelope.command {
      XCTAssertEqual(input.launch, CreateLaunchInput(profile: "Reviewer", prompt: prompt))
      XCTAssertTrue(input.background)
    } else {
      XCTFail("Expected create command envelope")
    }
    let output = try jsonObject(from: result.stdout)
    let data = try XCTUnwrap(output["data"] as? [String: Any])
    let outputLaunch = try XCTUnwrap(data["launch"] as? [String: Any])
    XCTAssertEqual(outputLaunch["profile_name"] as? String, "Reviewer")
    XCTAssertEqual(outputLaunch["agent"] as? String, "claude")
    let dispatch = try XCTUnwrap(data["dispatch"] as? [String: Any])
    XCTAssertEqual(dispatch["id"] as? String, "dispatch-create-pane")
    XCTAssertEqual(dispatch["state"] as? String, "pending")
  }

  func testProfilesListRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "profiles-list")
    let profile = ProfilesCommandProfile(
      id: UUID().uuidString,
      name: "Reviewer",
      enabled: true,
      runtime: "claude",
      availability: ProfilesCommandAvailability(status: .available)
    )
    let response = try CommandResponse(
      ok: true,
      command: "profiles",
      schemaVersion: "prowl.cli.profiles.v1",
      data: RawJSON(encoding: ProfilesCommandPayload(count: 1, profiles: [profile]))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["profiles", "list", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .profiles = envelope.command {
      // Expected read-only profile snapshot command.
    } else {
      XCTFail("Expected profiles command envelope")
    }
    let output = try jsonObject(from: result.stdout)
    XCTAssertEqual(output["schema_version"] as? String, "prowl.cli.profiles.v1")
  }

  func testProfilesListRendersAvailability() throws {
    let socketPath = temporarySocketPath(suffix: "profiles-list-human")
    let profile = ProfilesCommandProfile(
      id: UUID().uuidString,
      name: "Reviewer",
      enabled: false,
      runtime: "claude",
      availability: ProfilesCommandAvailability(
        status: .unknown,
        reason: "Availability check has not completed"
      )
    )
    let response = try CommandResponse(
      ok: true,
      command: "profiles",
      schemaVersion: "prowl.cli.profiles.v1",
      data: RawJSON(encoding: ProfilesCommandPayload(count: 1, profiles: [profile]))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["profiles", "list", "--no-color"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Reviewer  claude  disabled  unknown"), result.stdout)
    XCTAssertTrue(result.stdout.contains("Availability check has not completed"), result.stdout)
  }

  // MARK: - workflow

  private func withWorkflowFile(_ yaml: String, _ body: (URL, String) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "prowl-workflow-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "flow.pwlworkflow")
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    try Data(yaml.utf8).write(to: file.appending(path: "workflow.yaml"))
    try body(file, directory.appending(path: "missing.sock").path(percentEncoded: false))
  }

  func testWorkflowValidateIsLocalOnlyAndReportsAValidFile() throws {
    try withWorkflowFile(WorkflowFixtures.minimal(id: "demo")) { file, socketPath in
      let environment = [ProwlSocket.environmentKey: socketPath]
      let result = try runProwl(
        args: ["workflow", "validate", file.path(percentEncoded: false), "--json"], environment: environment)
      XCTAssertEqual(result.exitCode, 0, result.stderr)
      try assertResponseMatchesSchema(Data(result.stdout.utf8))
      let output = try jsonObject(from: result.stdout)
      XCTAssertEqual(output["command"] as? String, "workflow")
      XCTAssertEqual(output["schema_version"] as? String, "prowl.cli.workflow.v1")
      let data = try XCTUnwrap(output["data"] as? [String: Any])
      XCTAssertEqual(data["action"] as? String, "validate")
      XCTAssertEqual(data["valid"] as? Bool, true)
      XCTAssertEqual((data["workflow"] as? [String: Any])?["id"] as? String, "demo")
      XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath), "The command never touches the socket")

      let text = try runProwl(
        args: ["workflow", "validate", file.path(percentEncoded: false), "--no-color"], environment: environment)
      XCTAssertEqual(text.exitCode, 0, text.stderr)
      XCTAssertTrue(text.stdout.contains("OK"), text.stdout)
    }
  }

  func testWorkflowValidateFailsWithDiagnosticsForAnInvalidFile() throws {
    let yaml = WorkflowFixtures.minimal(id: "demo", extraSteps: "  - id: b\n    close: ghost")
    try withWorkflowFile(yaml) { file, socketPath in
      let environment = [ProwlSocket.environmentKey: socketPath]
      let result = try runProwl(
        args: ["workflow", "validate", file.path(percentEncoded: false), "--json"], environment: environment)
      XCTAssertEqual(result.exitCode, 1)
      try assertResponseMatchesSchema(Data(result.stdout.utf8))
      let output = try jsonObject(from: result.stdout)
      XCTAssertEqual(output["ok"] as? Bool, false)
      let error = try XCTUnwrap(output["error"] as? [String: Any])
      XCTAssertEqual(error["code"] as? String, "WORKFLOW_INVALID")
      let details = try XCTUnwrap(error["details"] as? [String: Any])
      let diagnostics = try XCTUnwrap(details["diagnostics"] as? [[String: Any]])
      XCTAssertEqual(diagnostics.map { $0["code"] as? String }, ["undefined_role"])
      XCTAssertEqual(diagnostics.first?["line"] as? Int, 12)

      let text = try runProwl(
        args: ["workflow", "validate", file.path(percentEncoded: false), "--no-color"], environment: environment)
      XCTAssertEqual(text.exitCode, 1)
      XCTAssertTrue(text.stdout.contains("error[undefined_role]"), text.stdout)
      XCTAssertTrue(text.stdout.contains("INVALID"), text.stdout)
    }
  }

  func testWorkflowSchemaPrintsTheDefinitionSchema() throws {
    let result = try runProwl(args: ["workflow", "schema", "--json"])
    XCTAssertEqual(result.exitCode, 0, result.stderr)
    try assertResponseMatchesSchema(Data(result.stdout.utf8))
    let data = try XCTUnwrap(try jsonObject(from: result.stdout)["data"] as? [String: Any])
    XCTAssertEqual(data["action"] as? String, "schema")
    let schema = try XCTUnwrap(data["schema"] as? [String: Any])
    XCTAssertEqual(schema["$id"] as? String, WorkflowJSONSchema.identifier)

    let text = try runProwl(args: ["workflow", "schema"])
    XCTAssertEqual(text.exitCode, 0, text.stderr)
    let printed = try jsonObject(from: text.stdout)
    XCTAssertEqual(printed["$id"] as? String, WorkflowJSONSchema.identifier)
  }

  func testWorkflowListRoundTripsThroughTheSocket() throws {
    let socketPath = temporarySocketPath(suffix: "workflow-list")
    let payload = WorkflowCommandPayload.list(
      WorkflowListPayload(
        worktree: WorkflowListWorktree(id: "wt", name: "main", path: "/Projects/App", rootPath: "/Projects/App"),
        sources: WorkflowListSources(bundle: nil, user: "/Users/me/.prowl/workflows", repo: "/Projects/App/.prowl/workflows"),
        workflows: [
          WorkflowListEntry(
            id: "demo", name: "Demo", description: nil, scope: .repo, path: "/Projects/App/.prowl/workflows/demo.yaml",
            enabled: true, valid: true, errors: 0, warnings: 1, shadowed: false)
        ]))
    let response = try CommandResponse(
      ok: true, command: "workflow", schemaVersion: "prowl.cli.workflow.v1", data: RawJSON(encoding: payload))

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath, response: response, args: ["workflow", "list", "main", "--json"])
    XCTAssertEqual(result.exitCode, 0, result.stderr)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    guard case .workflow(let input) = envelope.command else { return XCTFail("Expected a workflow envelope") }
    XCTAssertEqual(input.action, .list)
    XCTAssertEqual(input.target, .auto("main"))
    let output = try jsonObject(from: result.stdout)
    XCTAssertEqual(output["schema_version"] as? String, "prowl.cli.workflow.v1")

    let text = try runWithMockServer(
      socketPath: temporarySocketPath(suffix: "workflow-list-text"), response: response,
      args: ["workflow", "list", "--no-color"]).1
    XCTAssertEqual(text.exitCode, 0, text.stderr)
    XCTAssertTrue(text.stdout.contains("demo"), text.stdout)
    XCTAssertTrue(text.stdout.contains("[repo]"), text.stdout)
    XCTAssertTrue(text.stdout.contains("1 warning(s)"), text.stdout)
  }

  func testWorkflowDeliverAcceptsSixteenMiBWithJSONEscaping() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let body = Data(repeating: 10, count: WorkflowSizeLimits.payload)
    try body.write(to: file)
    let response = CommandResponse(
      ok: false, command: "workflow", schemaVersion: "prowl.cli.workflow.v1",
      error: .init(code: "STEP_NOT_EXPECTING", message: "No assigned task."))
    let (request, result) = try runWithMockServer(
      socketPath: temporarySocketPath(suffix: "workflow-large-deliver"), response: response,
      args: ["workflow", "deliver", "--file", file.path, "--json"])
    XCTAssertEqual(result.exitCode, 1)
    XCTAssertGreaterThan(request.count, 32 * 1024 * 1024)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: request)
    guard case .workflow(let input) = envelope.command else { return XCTFail("Expected workflow input") }
    XCTAssertEqual(input.body?.utf8.count, body.count)
  }

  func testWorkflowReadRoundTripsPagedContentWithoutAToken() throws {
    let runID = UUID().uuidString
    let payload = WorkflowCommandPayload.read(WorkflowContentPayload(
      run: runID, invocation: 3, role: "author", step: "brief", resource: "resource-1",
      body: "AA==", encoding: "base64", resources: [.init(id: "resource-1", name: "deliveries/brief.md")],
      offset: 4, nextOffset: 5, totalBytes: 8))
    let response = try CommandResponse(
      ok: true, command: "workflow", schemaVersion: "prowl.cli.workflow.v1", data: RawJSON(encoding: payload))
    let (request, result) = try runWithMockServer(
      socketPath: temporarySocketPath(suffix: "workflow-read"), response: response,
      args: ["workflow", "read", "resource-1", "--run", runID, "--invocation", "3", "--offset", "4", "--json"])
    XCTAssertEqual(result.exitCode, 0, result.stderr)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: request)
    guard case .workflow(let input) = envelope.command else { return XCTFail("Expected workflow input") }
    XCTAssertEqual(input.action, .read)
    XCTAssertEqual(input.runID, runID)
    XCTAssertEqual(input.invocation, 3)
    XCTAssertEqual(input.contentResource, "resource-1")
    XCTAssertEqual(input.contentOffset, 4)
    XCTAssertNil(input.token)
    let output = try jsonObject(from: result.stdout)
    let content = try XCTUnwrap(output["data"] as? [String: Any])
    XCTAssertEqual(content["body"] as? String, "AA==")
    XCTAssertEqual(content["encoding"] as? String, "base64")
    XCTAssertEqual(content["next_offset"] as? Int, 5)
    XCTAssertEqual(content["total_bytes"] as? Int, 8)
  }

  func testWorkflowRunAndDeliverRoundTripThroughTheSocket() throws {
    let output = WorkflowDeliveryRecordPayload(
      name: "brief", ordinal: 1, path: "/Projects/App/.prowl/workflow-runs/R/deliveries/brief.1.md",
      latestPath: "/Projects/App/.prowl/workflow-runs/R/deliveries/brief.md", verdict: nil,
      deliveredAt: "2026-08-30T01:02:03.000Z")
    let run = WorkflowRunPayload(
      id: "0BADCAFE-0000-4000-8000-000000000042",
      workflow: WorkflowIdentity(id: "review", name: "Review"),
      scope: .repo,
      definitionPath: "/Projects/App/.prowl/workflows/review.yaml",
      source: .live,
      status: WorkflowRunStatusPayload(state: "running"),
      step: "brief",
      role: "author",
      worktree: WorkflowRunWorktreePayload(id: "wt", name: "feature", branch: "feat/x", path: "/Projects/App"),
      runDirectory: "/Projects/App/.prowl/workflow-runs/R",
      bindings: [
        "author": WorkflowBindingPayload(
          source: .current,
          pane: WorkflowPaneBindingPayload(
            id: "00000000-0000-0000-0000-000000000001", tabID: nil, handle: "p1", displayName: "Claude Code",
            agent: "claude"))
      ],
      activation: WorkflowActivationPayload(
        ordinal: 1, step: "brief", role: "author", state: "waiting", dispatchID: "d-1", delivery: "brief",
        expect: WorkflowExpectationPayload(
          format: .markdown, sections: ["## Scope"], verdicts: nil, strict: false,
          completion: ["PROWL_WORKFLOW_TOKEN=T prowl workflow deliver -"]),
        deadline: nil),
      deliveries: [:],
      startedAt: "2026-08-30T01:00:00.000Z",
      updatedAt: "2026-08-30T01:00:00.000Z",
      finishedAt: nil,
      selfInitiated: WorkflowSelfInitiatedPayload(
        line: "[Prowl] Read /Projects/App/.prowl/workflow-runs/R/prompts/brief.1.md and follow it — finish with: PROWL_WORKFLOW_TOKEN=T prowl workflow deliver -",
        promptPath: "/Projects/App/.prowl/workflow-runs/R/prompts/brief.1.md",
        completion: ["PROWL_WORKFLOW_TOKEN=T prowl workflow deliver -"]))
    let runResponse = try CommandResponse(
      ok: true, command: "workflow", schemaVersion: "prowl.cli.workflow.v1",
      data: RawJSON(encoding: WorkflowCommandPayload.run(run)))
    let (runRequest, runResult) = try runWithMockServer(
      socketPath: temporarySocketPath(suffix: "workflow-run"), response: runResponse,
      args: ["workflow", "run", "review", "p3", "--role", "reviewer=Codex", "--input", "rounds=2", "--skip", "x", "--json"])
    XCTAssertEqual(runResult.exitCode, 0, runResult.stderr)
    let runEnvelope = try JSONDecoder().decode(CommandEnvelope.self, from: runRequest)
    guard case .workflow(let runInput) = runEnvelope.command else { return XCTFail("Expected a workflow envelope") }
    XCTAssertEqual(runInput.action, .run)
    XCTAssertEqual(runInput.workflow, "review")
    XCTAssertEqual(runInput.target, .auto("p3"))
    XCTAssertEqual(runInput.roleBindings, ["reviewer=Codex"])
    XCTAssertEqual(runInput.inputValues, ["rounds=2"])
    XCTAssertEqual(runInput.skippedSteps, ["x"])
    let (actionRequest, actionResult) = try runWithMockServer(
      socketPath: temporarySocketPath(suffix: "workflow-test-action"), response: runResponse,
      args: ["workflow", "test-action", "review", "local:count", "p3", "--input-json", "{\"count\":3}", "--json"])
    XCTAssertEqual(actionResult.exitCode, 0, actionResult.stderr)
    let actionEnvelope = try JSONDecoder().decode(CommandEnvelope.self, from: actionRequest)
    guard case .workflow(let actionInput) = actionEnvelope.command else { return XCTFail("Expected workflow input") }
    XCTAssertEqual(actionInput.testAction, "local:count")
    XCTAssertEqual(actionInput.actionInputs, ["count": .integer(3)])
    XCTAssertEqual(actionInput.target, .auto("p3"))
    let runOutput = try jsonObject(from: runResult.stdout)
    XCTAssertEqual(((runOutput["data"] as? [String: Any])?["self_initiated"] as? [String: Any])?["prompt_path"] as? String,
      "/Projects/App/.prowl/workflow-runs/R/prompts/brief.1.md")
    let runText = try runWithMockServer(
      socketPath: temporarySocketPath(suffix: "workflow-run-text"), response: runResponse,
      args: ["workflow", "run", "review", "--no-color"]).1
    XCTAssertEqual(runText.exitCode, 0, runText.stderr)
    XCTAssertTrue(runText.stdout.contains("Run: 0BADCAFE-0000-4000-8000-000000000042"), runText.stdout)
    XCTAssertTrue(runText.stdout.contains("Follow this line yourself"), runText.stdout)

    let deliverResponse = try CommandResponse(
      ok: true, command: "workflow", schemaVersion: "prowl.cli.workflow.v1",
      data: RawJSON(
        encoding: WorkflowCommandPayload.deliver(
          WorkflowDeliverPayload(
            run: run,
            delivery: WorkflowDeliveryPayload(
              state: .provisional, ordinal: 1, step: "brief", role: "author", record: output,
              warnings: [WorkflowDeliveryWarningPayload(code: "missing_sections", message: "missing section(s) ## Claims")])
          ))))
    let (deliverRequest, deliverResult) = try runWithMockServer(
      socketPath: temporarySocketPath(suffix: "workflow-deliver"), response: deliverResponse,
      args: ["workflow", "deliver", "-", "--verdict", "clean", "--json"],
      stdinData: Data("## Scope\nOnly the scope.\n".utf8),
      environment: [WorkflowSchema.tokenEnvironmentKey: "T"])
    XCTAssertEqual(deliverResult.exitCode, 0, deliverResult.stderr)
    let deliverEnvelope = try JSONDecoder().decode(CommandEnvelope.self, from: deliverRequest)
    guard case .workflow(let deliverInput) = deliverEnvelope.command else { return XCTFail("Expected a workflow envelope") }
    XCTAssertEqual(deliverInput.action, .deliver)
    XCTAssertEqual(deliverInput.body, "## Scope\nOnly the scope.\n")
    XCTAssertEqual(deliverInput.verdict, "clean")
    XCTAssertEqual(deliverInput.token, "T", "the token comes from the environment the step handed out")
    XCTAssertNil(deliverInput.runID)
    XCTAssertFalse(deliverInput.force)
    let deliverText = try runWithMockServer(
      socketPath: temporarySocketPath(suffix: "workflow-deliver-text"), response: deliverResponse,
      args: ["workflow", "deliver", "-", "--no-color"], stdinData: Data("x".utf8)).1
    XCTAssertEqual(deliverText.exitCode, 0, deliverText.stderr)
    XCTAssertTrue(deliverText.stdout.contains("Provisional"), deliverText.stdout)
    XCTAssertTrue(deliverText.stdout.contains("missing_sections"), deliverText.stdout)

    let noStdin = try runProwl(args: ["workflow", "deliver", "-"], environment: [ProwlSocket.environmentKey: "/nonexistent.sock"])
    XCTAssertNotEqual(noStdin.exitCode, 0)
  }

  // MARK: - skills (local-only)

  func testSkillsListIsLocalOnlyAndValidatesAgainstSchema() throws {
    try withSkillsFixture { fixture in
      let result = try runProwl(args: ["skills", "list", "--json"], environment: fixture.environment)

      XCTAssertEqual(result.exitCode, 0, result.stderr)
      XCTAssertEqual(result.stderr, "")
      try assertResponseMatchesSchema(Data(result.stdout.utf8))
      let output = try jsonObject(from: result.stdout)
      XCTAssertEqual(output["command"] as? String, "skills")
      XCTAssertEqual(output["schema_version"] as? String, "prowl.cli.skills.v1")
      let data = try XCTUnwrap(output["data"] as? [String: Any])
      XCTAssertEqual(data["action"] as? String, "list")
      let skills = try XCTUnwrap(data["skills"] as? [[String: Any]])
      XCTAssertEqual(skills.map { $0["id"] as? String }, ["prowl-cli", "reviewer"])
      XCTAssertEqual(skills.map { $0["audience"] as? String }, ["user", "workflow"])
      let targets = try XCTUnwrap(skills[0]["targets"] as? [[String: Any]])
      XCTAssertEqual(targets.map { $0["id"] as? String }, ["claude", "codex", "agents"])
      XCTAssertEqual(targets.map { $0["detected"] as? Bool }, [true, false, true])
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketPath), "The command never touches the socket")

      let text = try runProwl(args: ["skills", "list", "--no-color"], environment: fixture.environment)
      XCTAssertEqual(text.exitCode, 0, text.stderr)
      XCTAssertTrue(text.stdout.contains("prowl-cli"))
      XCTAssertTrue(text.stdout.contains("workflow"))
      XCTAssertTrue(text.stdout.contains("not installed"))
    }
  }

  func testSkillsInstallStatusUninstallRoundTripAcrossAllTargets() throws {
    try withSkillsFixture { fixture in
      let install = try runProwl(
        args: [
          "skills", "install", "prowl-cli", "--target", "claude", "--target", "codex", "--target", "agents", "--json",
        ],
        environment: fixture.environment
      )
      XCTAssertEqual(install.exitCode, 0, install.stderr)
      XCTAssertEqual(install.stderr, "")
      try assertResponseMatchesSchema(Data(install.stdout.utf8))
      let installData = try XCTUnwrap(try jsonObject(from: install.stdout)["data"] as? [String: Any])
      XCTAssertEqual(installData["action"] as? String, "install")
      XCTAssertEqual(installData["scope"] as? String, "user")
      XCTAssertEqual(installData["root"] as? String, fixture.home.path(percentEncoded: false))
      XCTAssertNil(installData["note"])
      let installResults = try XCTUnwrap(installData["results"] as? [[String: Any]])
      XCTAssertEqual(installResults.map { $0["target"] as? String }, ["claude", "codex", "agents"])
      XCTAssertEqual(
        installResults.map { $0["before"] as? String }, ["not_installed", "not_installed", "not_installed"])
      XCTAssertEqual(installResults.map { $0["after"] as? String }, ["installed", "installed", "installed"])
      for target in [".claude", ".codex", ".agents"] {
        let link = fixture.home.appending(path: "\(target)/skills/prowl-cli").path(percentEncoded: false)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), fixture.skillPath("prowl-cli"))
      }

      let list = try runProwl(args: ["skills", "list", "--json"], environment: fixture.environment)
      XCTAssertEqual(list.exitCode, 0, list.stderr)
      let listData = try XCTUnwrap(try jsonObject(from: list.stdout)["data"] as? [String: Any])
      let listed = try XCTUnwrap(listData["skills"] as? [[String: Any]])
      let statuses = try XCTUnwrap(listed[0]["targets"] as? [[String: Any]]).map { $0["status"] as? String }
      XCTAssertEqual(statuses, ["installed", "installed", "installed"])

      let uninstall = try runProwl(args: ["skills", "uninstall", "--json"], environment: fixture.environment)
      XCTAssertEqual(uninstall.exitCode, 0, uninstall.stderr)
      try assertResponseMatchesSchema(Data(uninstall.stdout.utf8))
      let uninstallData = try XCTUnwrap(try jsonObject(from: uninstall.stdout)["data"] as? [String: Any])
      XCTAssertEqual(uninstallData["action"] as? String, "uninstall")
      let uninstallResults = try XCTUnwrap(uninstallData["results"] as? [[String: Any]])
      XCTAssertEqual(uninstallResults.map { $0["target"] as? String }, ["claude", "codex", "agents"])
      XCTAssertEqual(
        uninstallResults.map { $0["after"] as? String }, ["not_installed", "not_installed", "not_installed"])
      for target in [".claude", ".codex", ".agents"] {
        let link = fixture.home.appending(path: "\(target)/skills/prowl-cli").path(percentEncoded: false)
        XCTAssertNil(try? FileManager.default.attributesOfItem(atPath: link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.home.appending(path: "\(target)/skills").path()))
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.skillPath("prowl-cli") + "/SKILL.md"))
    }
  }

  func testSkillsInstallRefusesWorkflowSkillsAndRealDirectoriesInBothOutputModes() throws {
    try withSkillsFixture { fixture in
      let workflow = try runProwl(args: ["skills", "install", "reviewer", "--json"], environment: fixture.environment)
      XCTAssertNotEqual(workflow.exitCode, 0)
      try assertResponseMatchesSchema(Data(workflow.stdout.utf8))
      let workflowError = try XCTUnwrap(try jsonObject(from: workflow.stdout)["error"] as? [String: Any])
      XCTAssertEqual(workflowError["code"] as? String, "SKILL_NOT_INSTALLABLE")

      let workflowText = try runProwl(args: ["skills", "install", "reviewer"], environment: fixture.environment)
      XCTAssertNotEqual(workflowText.exitCode, 0)
      XCTAssertEqual(workflowText.stdout, "")
      XCTAssertTrue(workflowText.stderr.contains("error [SKILL_NOT_INSTALLABLE]"))

      let realDirectory = fixture.home.appending(path: ".claude/skills/prowl-cli")
      try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
      try Data("keep".utf8).write(to: realDirectory.appending(path: "SKILL.md"))
      let conflict = try runProwl(
        args: ["skills", "install", "prowl-cli", "--target", "claude", "--json"],
        environment: fixture.environment
      )
      XCTAssertNotEqual(conflict.exitCode, 0)
      try assertResponseMatchesSchema(Data(conflict.stdout.utf8))
      let conflictError = try XCTUnwrap(try jsonObject(from: conflict.stdout)["error"] as? [String: Any])
      XCTAssertEqual(conflictError["code"] as? String, "INSTALL_CONFLICT")
      XCTAssertEqual(try Data(contentsOf: realDirectory.appending(path: "SKILL.md")), Data("keep".utf8))
      XCTAssertNil(
        try? FileManager.default.destinationOfSymbolicLink(atPath: realDirectory.path(percentEncoded: false)))

      let unknownTarget = try runProwl(
        args: ["skills", "install", "--target", "cursor", "--json"], environment: fixture.environment)
      XCTAssertNotEqual(unknownTarget.exitCode, 0)
      let unknownTargetError = try XCTUnwrap(try jsonObject(from: unknownTarget.stdout)["error"] as? [String: Any])
      XCTAssertEqual(unknownTargetError["code"] as? String, "TARGET_NOT_FOUND")

      let unknownSkill = try runProwl(args: ["skills", "path", "missing", "--json"], environment: fixture.environment)
      XCTAssertNotEqual(unknownSkill.exitCode, 0)
      let unknownSkillError = try XCTUnwrap(try jsonObject(from: unknownSkill.stdout)["error"] as? [String: Any])
      XCTAssertEqual(unknownSkillError["code"] as? String, "SKILL_NOT_FOUND")
    }
  }

  func testSkillsProjectScopePrintsHygieneNoteOnceAndNeverTouchesGit() throws {
    try withSkillsFixture { fixture in
      let repo = fixture.root.appending(path: "repo", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: repo.appending(path: ".git/info"), withIntermediateDirectories: true)
      try Data("ref: refs/heads/main\n".utf8).write(to: repo.appending(path: ".git/HEAD"))
      try FileManager.default.createDirectory(at: repo.appending(path: ".claude"), withIntermediateDirectories: true)
      let gitBefore = try gitEntries(repo)

      let text = try runProwl(
        args: ["skills", "install", "--scope", "project", "--path", repo.path(percentEncoded: false), "--no-color"],
        environment: fixture.environment
      )
      XCTAssertEqual(text.exitCode, 0, text.stderr)
      XCTAssertEqual(text.stderr.components(separatedBy: ".git/info/exclude").count - 1, 1, text.stderr)
      XCTAssertFalse(text.stdout.contains(".git/info/exclude"))
      XCTAssertTrue(text.stdout.contains("claude"))
      let link = repo.appending(path: ".claude/skills/prowl-cli").path(percentEncoded: false)
      XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), fixture.skillPath("prowl-cli"))

      let json = try runProwl(
        args: ["skills", "uninstall", "--scope", "project", "--path", repo.path(percentEncoded: false), "--json"],
        environment: fixture.environment
      )
      XCTAssertEqual(json.exitCode, 0, json.stderr)
      XCTAssertEqual(json.stderr, "")
      try assertResponseMatchesSchema(Data(json.stdout.utf8))
      let data = try XCTUnwrap(try jsonObject(from: json.stdout)["data"] as? [String: Any])
      XCTAssertEqual(data["scope"] as? String, "project")
      XCTAssertEqual(data["root"] as? String, repo.path(percentEncoded: false).trimmingTrailingPathSeparator())
      let note = try XCTUnwrap(data["note"] as? String)
      XCTAssertEqual(note.components(separatedBy: ".git/info/exclude").count - 1, 1)
      XCTAssertNil(try? FileManager.default.attributesOfItem(atPath: link))
      XCTAssertEqual(try gitEntries(repo), gitBefore)
    }
  }

  func testSkillsPathPrintsBundledDirectoryAndFailsClosedWithoutBundle() throws {
    try withSkillsFixture { fixture in
      let path = try runProwl(args: ["skills", "path", "reviewer"], environment: fixture.environment)
      XCTAssertEqual(path.exitCode, 0, path.stderr)
      XCTAssertEqual(path.stdout, fixture.skillPath("reviewer") + "\n")
      XCTAssertEqual(path.stderr, "")

      let pathJSON = try runProwl(args: ["skills", "path", "reviewer", "--json"], environment: fixture.environment)
      XCTAssertEqual(pathJSON.exitCode, 0, pathJSON.stderr)
      try assertResponseMatchesSchema(Data(pathJSON.stdout.utf8))
      let data = try XCTUnwrap(try jsonObject(from: pathJSON.stdout)["data"] as? [String: Any])
      let skill = try XCTUnwrap(data["skill"] as? [String: Any])
      XCTAssertEqual(skill["path"] as? String, fixture.skillPath("reviewer"))
      XCTAssertEqual(skill["audience"] as? String, "workflow")

      var brokenEnvironment = fixture.environment
      brokenEnvironment["PROWL_SKILLS_DIR"] = fixture.root.appending(path: "missing-skills").path(percentEncoded: false)
      let missing = try runProwl(args: ["skills", "list", "--json"], environment: brokenEnvironment)
      XCTAssertNotEqual(missing.exitCode, 0)
      try assertResponseMatchesSchema(Data(missing.stdout.utf8))
      let error = try XCTUnwrap(try jsonObject(from: missing.stdout)["error"] as? [String: Any])
      XCTAssertEqual(error["code"] as? String, "BUNDLE_NOT_FOUND")

      let missingText = try runProwl(args: ["skills", "list"], environment: brokenEnvironment)
      XCTAssertNotEqual(missingText.exitCode, 0)
      XCTAssertEqual(missingText.stdout, "")
      XCTAssertTrue(missingText.stderr.contains("error [BUNDLE_NOT_FOUND]"))
    }
  }

  private struct SkillsFixture {
    let root: URL
    let home: URL
    let skillsRoot: URL
    let socketPath: String

    var environment: [String: String] {
      [
        ProwlSocket.environmentKey: socketPath,
        "PROWL_SKILLS_DIR": skillsRoot.path(percentEncoded: false),
        "HOME": home.path(percentEncoded: false),
      ]
    }

    func skillPath(_ id: String) -> String {
      skillsRoot.appending(path: id, directoryHint: .notDirectory).path(percentEncoded: false)
    }
  }

  private func withSkillsFixture(_ body: (SkillsFixture) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-skills-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
      .standardizedFileURL
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appending(path: "home", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home.appending(path: ".agents"), withIntermediateDirectories: true)

    let skillsRoot = root.appending(path: "skills", directoryHint: .isDirectory)
    for (id, extra) in [("prowl-cli", ""), ("reviewer", "metadata:\n  prowl-install: workflow\n")] {
      let directory = skillsRoot.appending(path: id, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("---\nname: \(id)\ndescription: \(id) description.\n\(extra)---\n".utf8)
        .write(to: directory.appending(path: "SKILL.md"))
    }

    let fixture = SkillsFixture(
      root: root,
      home: home,
      skillsRoot: skillsRoot,
      socketPath: root.appending(path: "missing.sock").path(percentEncoded: false)
    )
    try body(fixture)
  }

  private func gitEntries(_ repo: URL) throws -> [String] {
    let enumerator = FileManager.default.enumerator(atPath: repo.appending(path: ".git").path(percentEncoded: false))
    var entries: [String] = []
    while let entry = enumerator?.nextObject() as? String {
      entries.append(entry)
    }
    return entries.sorted()
  }

  func testCreatePaneCommandRendersAnchorAndDirection() throws {
    let socketPath = temporarySocketPath(suffix: "create-pane-human")
    let response = try CommandResponse(
      ok: true,
      command: "create",
      schemaVersion: "prowl.cli.create.v1",
      data: RawJSON(
        encoding: makeLifecyclePayload(
          resource: .pane,
          anchor: makeTabTarget(paneID: "anchor-pane"),
          direction: .upward
        )
      )
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["create", "pane", "p12", "--direction", "up", "--no-color"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Created pane"), result.stdout)
    XCTAssertTrue(result.stdout.contains("pane-123"), result.stdout)
    XCTAssertTrue(result.stdout.contains("anchor: anchor-pane"), result.stdout)
    XCTAssertTrue(result.stdout.contains("direction: up"), result.stdout)
  }

  func testCloseCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "close-pane")
    let response = try CommandResponse(
      ok: true,
      command: "close",
      schemaVersion: "prowl.cli.close.v1",
      data: RawJSON(encoding: makeLifecyclePayload(resource: .pane))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["close", "p12", "--force", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .close(let input) = envelope.command {
      XCTAssertEqual(input.selector, .auto("p12"))
      XCTAssertTrue(input.force)
    } else {
      XCTFail("Expected close command envelope")
    }
  }

  func testCloseAcceptsTypedTabSelector() throws {
    let socketPath = temporarySocketPath(suffix: "close-tab")
    let response = try CommandResponse(
      ok: true,
      command: "close",
      schemaVersion: "prowl.cli.close.v1",
      data: RawJSON(encoding: makeLifecyclePayload(resource: .tab))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["close", "--tab", "t6", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .close(let input) = envelope.command {
      XCTAssertEqual(input.selector, .tab("t6"))
    } else {
      XCTFail("Expected close command envelope")
    }
  }

  func testCloseRejectsMissingTargetBeforeTransport() throws {
    let result = try runProwl(args: ["close", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "close")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testCloseRejectsWorktreeBeforeTransport() throws {
    let result = try runProwl(args: ["close", "App", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "close")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testCloseRejectsWorktreeSelectorBeforeTransport() throws {
    let result = try runProwl(args: ["close", "--worktree", "App", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "close")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testCreateTabRejectsPaneSelectorBeforeTransport() throws {
    let result = try runProwl(args: ["create", "tab", "--pane", "p12", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "create")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testDeprecatedTabCreateWarnsWithoutChangingLegacyEnvelope() throws {
    let socketPath = temporarySocketPath(suffix: "deprecated-tab-create")
    let response = CommandResponse(
      ok: true,
      command: "tab",
      schemaVersion: "prowl.cli.tab.v1"
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["tab", "create", "--worktree", "App", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stderr.contains("deprecated"))
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .tab = envelope.command {
      // Expected legacy transport contract during the deprecation window.
    } else {
      XCTFail("Expected tab command envelope")
    }
  }

  func testTabCreateCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "tab-create")
    let response = try CommandResponse(
      ok: true,
      command: "tab",
      schemaVersion: "prowl.cli.tab.v1",
      data: RawJSON(encoding: makeTabPayload(action: .create))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["tab", "create", "--worktree", "App", "--path", "/Projects/App", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .tab(let input) = envelope.command {
      XCTAssertEqual(input.action, .create)
      XCTAssertEqual(input.selector, .worktree("App"))
      XCTAssertEqual(input.path, "/Projects/App")
    } else {
      XCTFail("Expected tab command envelope")
    }
  }

  func testTabCloseCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "tab-close")
    let response = try CommandResponse(
      ok: true,
      command: "tab",
      schemaVersion: "prowl.cli.tab.v1",
      data: RawJSON(encoding: makeTabPayload(action: .close))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["tab", "close", "--tab", "tab-123", "--force", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .tab(let input) = envelope.command {
      XCTAssertEqual(input.action, .close)
      XCTAssertEqual(input.selector, .tab("tab-123"))
      XCTAssertNil(input.path)
      XCTAssertTrue(input.force)
    } else {
      XCTFail("Expected tab command envelope")
    }
  }

  func testTabCloseRejectsMissingTargetBeforeTransport() throws {
    let result = try runProwl(args: ["tab", "close", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "tab")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testPaneCloseCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "pane-close")
    let response = try CommandResponse(
      ok: true,
      command: "pane",
      schemaVersion: "prowl.cli.pane.v1",
      data: RawJSON(encoding: makePanePayload(action: .close))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["pane", "close", "--pane", "pane-123", "--force", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .pane(let input) = envelope.command {
      XCTAssertEqual(input.action, .close)
      XCTAssertEqual(input.selector, .pane("pane-123"))
      XCTAssertTrue(input.force)
    } else {
      XCTFail("Expected pane command envelope")
    }
  }

  func testPaneCloseRejectsMissingTargetBeforeTransport() throws {
    let result = try runProwl(args: ["pane", "close", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "pane")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testFocusRejectsMultipleSelectorsBeforeTransport() throws {
    let result = try runProwl(args: ["focus", "--worktree", "Prowl", "--pane", "pane-123", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "focus")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testFocusCommandTextRenderingFromSocket() throws {
    let socketPath = temporarySocketPath(suffix: "focus-text")
    let response = try CommandResponse(
      ok: true,
      command: "focus",
      schemaVersion: "prowl.cli.focus.v1",
      data: RawJSON(
        encoding: FocusResponseData(
          requested: FocusRequested(selector: "pane", value: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764"),
          resolvedVia: "pane",
          broughtToFront: true,
          target: FocusResponseTarget(
            worktree: ListWorktree(
              id: "Prowl:/Users/onevcat/Projects/Prowl",
              name: "Prowl",
              path: "/Users/onevcat/Projects/Prowl",
              rootPath: "/Users/onevcat/Projects/Prowl",
              kind: "git"
            ),
            tab: FocusResponseTab(
              id: "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0",
              title: "Prowl 1",
              selected: true
            ),
            pane: FocusResponsePane(
              id: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764",
              title: "zsh",
              cwd: "/Users/onevcat/Projects/Prowl",
              focused: true
            )
          )
        ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["focus"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Focused Prowl:Prowl"), "Missing focus header: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("requested: pane"), "Missing requested field: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("resolved: pane"), "Missing resolved field: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("tab: Prowl 1"), "Missing tab field: \(result.stdout)")
  }

  func testListCommandTextRenderingFromSocket() throws {
    let socketPath = temporarySocketPath(suffix: "list-text")
    let response = try CommandResponse(
      ok: true,
      command: "list",
      schemaVersion: "prowl.cli.list.v1",
      data: RawJSON(
        encoding: ListResponseData(
          count: 1,
          items: [
            ListResponseItem(
              worktree: ListWorktree(
                id: "Prowl:/Users/onevcat/Projects/Prowl",
                name: "Prowl",
                path: "/Users/onevcat/Projects/Prowl",
                rootPath: "/Users/onevcat/Projects/Prowl",
                kind: "git"
              ),
              tab: ListTab(
                id: "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0",
                handle: 7,
                title: "Prowl 1",
                selected: true
              ),
              pane: ListPane(
                id: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764",
                handle: 8,
                title: "zsh",
                cwd: "/Users/onevcat/Projects/Prowl",
                focused: true
              ),
              task: ListTask(status: "running")
            )
          ]
        ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["list"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Prowl:Prowl (running)"), "Missing worktree header: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Tab 1:"), "Missing tab label: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("t7"), "Missing tab handle: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Pane 1:"), "Missing pane label: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("p8"), "Missing pane handle: \(result.stdout)")
    XCTAssertFalse(result.stdout.contains("6E1A2A10-D99F-4E3F-920C-D93AA3C05764"))
  }

  func testListEmptyPayloadShowsNoPanesFound() throws {
    let socketPath = temporarySocketPath(suffix: "list-empty")
    let response = try CommandResponse(
      ok: true,
      command: "list",
      schemaVersion: "prowl.cli.list.v1",
      data: RawJSON(encoding: ListResponseData(count: 0, items: []))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["list"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("No panes found."), "Expected empty message: \(result.stdout)")
  }

  func testAgentsCommandTextRenderingFromSocket() throws {
    let socketPath = temporarySocketPath(suffix: "agents-text")
    let response = try CommandResponse(
      ok: true,
      command: "agents",
      schemaVersion: "prowl.cli.agents.v1",
      data: RawJSON(
        encoding: AgentsResponseData(
          count: 3,
          agents: [
            makeAgentResponse(
              id: "done-pane",
              name: "codex",
              status: "done",
              projectName: "Prowl",
              branch: "main",
              tabTitle: "Done tab",
              detectionReason: "legacy.detector",
              session: AgentsResponseSession(
                id: "019f4e9e-1234-4567-89ab-0123456789ab",
                path: "/Users/me/.codex/sessions/rollout.jsonl",
                confidence: "exact",
                source: "open_file"
              )
            ),
            makeAgentResponse(
              id: "blocked-pane",
              handle: 3,
              name: "omp",
              status: "blocked",
              projectName: "Prowl",
              branch: "feature/cli-agents",
              tabTitle: "issue 330"
            ),
            makeAgentResponse(
              id: "working-pane",
              name: "claude",
              status: "working",
              projectName: "Notes",
              branch: "main",
              tabTitle: "review"
            ),
          ]
        ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["agents"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let lines = result.stdout.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.count, 3, "Unexpected agents output: \(result.stdout)")
    XCTAssertTrue(lines[0].contains("Blocked"), "Expected blocked first: \(result.stdout)")
    XCTAssertTrue(lines[0].contains("omp"), "Missing agent name: \(result.stdout)")
    XCTAssertTrue(lines[0].contains("Prowl:feature/cli-agents"), "Missing project label: \(result.stdout)")
    XCTAssertTrue(lines[0].contains("issue 330"), "Missing tab title: \(result.stdout)")
    XCTAssertTrue(lines[0].contains("p3"), "Missing pane handle: \(result.stdout)")
    XCTAssertFalse(lines[0].contains("blocked-pane"), "Unexpected UUID fallback: \(result.stdout)")
    XCTAssertTrue(lines[1].contains("Working"), "Expected working second: \(result.stdout)")
    XCTAssertTrue(lines[2].contains("Done"), "Expected done third: \(result.stdout)")
    XCTAssertTrue(lines[2].contains("session=019f4e9e-1234-4567-89ab-0123456789ab [exact]"))
    XCTAssertFalse(result.stdout.contains("legacy.detector"), "Detection reason must remain JSON-only")
  }

  func testAgentsEmptyPayloadShowsNoAgentsFound() throws {
    let socketPath = temporarySocketPath(suffix: "agents-empty")
    let response = try CommandResponse(
      ok: true,
      command: "agents",
      schemaVersion: "prowl.cli.agents.v1",
      data: RawJSON(encoding: AgentsResponseData(count: 0, agents: []))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["agents"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("No agents found."), "Expected empty message: \(result.stdout)")
  }

  func testListMultipleWorktreesGroupedWithBlankLine() throws {
    let socketPath = temporarySocketPath(suffix: "list-multi-wt")
    let response = try CommandResponse(
      ok: true,
      command: "list",
      schemaVersion: "prowl.cli.list.v1",
      data: RawJSON(
        encoding: ListResponseData(
          count: 2,
          items: [
            ListResponseItem(
              worktree: ListWorktree(
                id: "wt-1", name: "main",
                path: "/Projects/Alpha", rootPath: "/Projects/Alpha", kind: "git"
              ),
              tab: ListTab(id: "t1", title: "Tab A", selected: true),
              pane: ListPane(id: "p1", title: "zsh", cwd: "/Projects/Alpha", focused: true),
              task: ListTask(status: "running")
            ),
            ListResponseItem(
              worktree: ListWorktree(
                id: "wt-2", name: "develop",
                path: "/Projects/Beta", rootPath: "/Projects/Beta", kind: "git"
              ),
              tab: ListTab(id: "t2", title: "Tab B", selected: true),
              pane: ListPane(id: "p2", title: "zsh", cwd: "/Projects/Beta", focused: false),
              task: ListTask(status: "idle")
            ),
          ]
        ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["list"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Alpha:main (running)"), "Missing first worktree: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Beta:develop (idle)"), "Missing second worktree: \(result.stdout)")

    // Worktrees should be separated by a blank line.
    let lines = result.stdout.components(separatedBy: "\n")
    let blankIndices = lines.enumerated().filter { $0.element.isEmpty }.map(\.offset)
    XCTAssertFalse(blankIndices.isEmpty, "Expected blank line between worktrees: \(result.stdout)")
  }

  func testListCwdSuppressedWhenMatchingWorktreePath() throws {
    let socketPath = temporarySocketPath(suffix: "list-cwd-dedup")
    let response = try CommandResponse(
      ok: true,
      command: "list",
      schemaVersion: "prowl.cli.list.v1",
      data: RawJSON(
        encoding: ListResponseData(
          count: 2,
          items: [
            ListResponseItem(
              worktree: ListWorktree(
                id: "wt-1", name: "main",
                path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
              ),
              tab: ListTab(id: "t1", title: "Tab 1", selected: true),
              pane: ListPane(id: "p-same", title: "zsh", cwd: "/Projects/App", focused: true),
              task: ListTask(status: "idle")
            ),
            ListResponseItem(
              worktree: ListWorktree(
                id: "wt-1", name: "main",
                path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
              ),
              tab: ListTab(id: "t1", title: "Tab 1", selected: true),
              pane: ListPane(id: "p-diff", title: "zsh", cwd: "/Users/onevcat", focused: false),
              task: ListTask(status: "idle")
            ),
          ]
        ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["list"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let lines = result.stdout.components(separatedBy: "\n")

    // Pane whose cwd matches worktree path should NOT repeat the cwd.
    let sameLine = lines.first { $0.contains("p-same") }
    XCTAssertNotNil(sameLine, "Missing same-cwd pane")
    XCTAssertFalse(sameLine?.contains("/Projects/App") ?? true, "cwd should be suppressed: \(sameLine ?? "")")

    // Pane whose cwd differs should show it.
    let diffLine = lines.first { $0.contains("p-diff") }
    XCTAssertNotNil(diffLine, "Missing diff-cwd pane")
    XCTAssertTrue(diffLine?.contains("/Users/onevcat") ?? false, "cwd should be shown: \(diffLine ?? "")")
  }

  func testListMultiTabMultiPaneNumbering() throws {
    let socketPath = temporarySocketPath(suffix: "list-numbering")
    let response = try CommandResponse(
      ok: true,
      command: "list",
      schemaVersion: "prowl.cli.list.v1",
      data: RawJSON(
        encoding: ListResponseData(
          count: 3,
          items: [
            ListResponseItem(
              worktree: ListWorktree(
                id: "wt-1", name: "main",
                path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
              ),
              tab: ListTab(id: "tab-a", title: "Tab A", selected: false),
              pane: ListPane(id: "pa1", title: "zsh", cwd: "/Projects/App", focused: false),
              task: ListTask(status: "idle")
            ),
            ListResponseItem(
              worktree: ListWorktree(
                id: "wt-1", name: "main",
                path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
              ),
              tab: ListTab(id: "tab-b", title: "Tab B", selected: true),
              pane: ListPane(id: "pb1", title: "vim", cwd: "/Projects/App", focused: true),
              task: ListTask(status: "idle")
            ),
            ListResponseItem(
              worktree: ListWorktree(
                id: "wt-1", name: "main",
                path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
              ),
              tab: ListTab(id: "tab-b", title: "Tab B", selected: true),
              pane: ListPane(id: "pb2", title: "htop", cwd: "/Projects/App", focused: false),
              task: ListTask(status: "idle")
            ),
          ]
        ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["list"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Tab 1:"), "Missing Tab 1: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Tab 2:"), "Missing Tab 2: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Pane 1:"), "Missing Pane 1: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Pane 2:"), "Missing Pane 2: \(result.stdout)")
  }

  func testListNoColorFlagProducesCleanOutput() throws {
    let socketPath = temporarySocketPath(suffix: "list-no-color")
    let response = try CommandResponse(
      ok: true,
      command: "list",
      schemaVersion: "prowl.cli.list.v1",
      data: RawJSON(
        encoding: ListResponseData(
          count: 1,
          items: [
            ListResponseItem(
              worktree: ListWorktree(
                id: "wt-1", name: "main",
                path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
              ),
              tab: ListTab(id: "t1", title: "Tab A", selected: true),
              pane: ListPane(id: "p1", title: "zsh", cwd: "/Projects/App", focused: true),
              task: ListTask(status: "running")
            )
          ]
        ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["list", "--no-color"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertFalse(result.stdout.contains("\u{1B}["), "Should not contain ANSI escape codes: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("App:main (running)"), "Missing header: \(result.stdout)")
  }

  // MARK: - Send command tests

  func testSendCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "send")
    let response = try CommandResponse(
      ok: true,
      command: "send",
      schemaVersion: "prowl.cli.send.v1",
      data: RawJSON(
        encoding: SendResponseData(
          target: SendResponseTarget(
            worktree: ListWorktree(
              id: "Prowl:/Projects/Prowl", name: "Prowl",
              path: "/Projects/Prowl", rootPath: "/Projects/Prowl", kind: "git"
            ),
            tab: SendResponseTab(id: "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0", title: "Prowl 1", selected: true),
            pane: SendResponsePane(
              id: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764",
              title: "zsh", cwd: "/Projects/Prowl", focused: true
            )
          ),
          input: SendResponseInput(source: "argv", characters: 10, bytes: 10, trailingEnterSent: true),
          createdTab: false,
          wait: SendResponseWait(exitCode: 0, durationMs: 1234)
        ))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["send", "echo hello", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .send(let input) = envelope.command {
      XCTAssertEqual(input.text, "echo hello")
      XCTAssertEqual(input.source, .argv)
      XCTAssertTrue(input.trailingEnter)
      XCTAssertTrue(input.wait)
    } else {
      XCTFail("Expected send command envelope")
    }

    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, true)
    XCTAssertEqual(payload["command"] as? String, "send")
    let data = try XCTUnwrap(payload["data"] as? [String: Any])
    let wait = try XCTUnwrap(data["wait"] as? [String: Any])
    XCTAssertEqual(wait["exit_code"] as? Int, 0)
    XCTAssertEqual(wait["duration_ms"] as? Int, 1234)
  }

  func testSendNoWaitJsonShowsNullWait() throws {
    let socketPath = temporarySocketPath(suffix: "send-no-wait")
    let response = try CommandResponse(
      ok: true,
      command: "send",
      schemaVersion: "prowl.cli.send.v1",
      data: RawJSON(
        encoding: SendResponseData(
          target: SendResponseTarget(
            worktree: ListWorktree(
              id: "wt-1", name: "main",
              path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
            ),
            tab: SendResponseTab(id: "t1", title: "Tab 1", selected: true),
            pane: SendResponsePane(id: "p1", title: "zsh", cwd: "/Projects/App", focused: true)
          ),
          input: SendResponseInput(source: "argv", characters: 5, bytes: 5, trailingEnterSent: true),
          createdTab: false,
          wait: nil
        ))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["send", "hello", "--no-wait", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .send(let input) = envelope.command {
      XCTAssertFalse(input.wait)
    } else {
      XCTFail("Expected send command envelope")
    }

    let payload = try jsonObject(from: result.stdout)
    let data = try XCTUnwrap(payload["data"] as? [String: Any])
    XCTAssertTrue(data["wait"] is NSNull, "wait should be null: \(data["wait"] ?? "missing")")
  }

  func testSendTextRenderingFromSocket() throws {
    let socketPath = temporarySocketPath(suffix: "send-text")
    let response = try CommandResponse(
      ok: true,
      command: "send",
      schemaVersion: "prowl.cli.send.v1",
      data: RawJSON(
        encoding: SendResponseData(
          target: SendResponseTarget(
            worktree: ListWorktree(
              id: "wt-1", name: "main",
              path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
            ),
            tab: SendResponseTab(id: "t1", title: "Tab 1", selected: true),
            pane: SendResponsePane(id: "p1", title: "zsh", cwd: "/Projects/App", focused: true)
          ),
          input: SendResponseInput(source: "argv", characters: 10, bytes: 10, trailingEnterSent: true),
          createdTab: false,
          wait: SendResponseWait(exitCode: 0, durationMs: 350)
        ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["send", "echo hello"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Sent to"), "Missing 'Sent to' header: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("App:main"), "Missing worktree: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("zsh"), "Missing pane title: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("chars:"), "Missing chars label: \(result.stdout)")
  }

  func testSendNoColorProducesCleanOutput() throws {
    let socketPath = temporarySocketPath(suffix: "send-no-color")
    let response = try CommandResponse(
      ok: true,
      command: "send",
      schemaVersion: "prowl.cli.send.v1",
      data: RawJSON(
        encoding: SendResponseData(
          target: SendResponseTarget(
            worktree: ListWorktree(
              id: "wt-1", name: "main",
              path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
            ),
            tab: SendResponseTab(id: "t1", title: "Tab 1", selected: true),
            pane: SendResponsePane(id: "p1", title: "zsh", cwd: "/Projects/App", focused: true)
          ),
          input: SendResponseInput(source: "argv", characters: 5, bytes: 5, trailingEnterSent: true),
          createdTab: false,
          wait: SendResponseWait(exitCode: 0, durationMs: 100)
        ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["send", "hello", "--no-color"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertFalse(result.stdout.contains("\u{1B}["), "Should not contain ANSI escape codes: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Sent to"), "Missing header: \(result.stdout)")
  }

  func testSendEmptyInputReturnsError() throws {
    let result = try runProwl(args: ["send", "--json"])
    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, "EMPTY_INPUT")
  }

  func testSendTimeoutValidation() throws {
    let result = try runProwl(args: ["send", "hello", "--timeout", "0", "--json"])
    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, "INVALID_ARGUMENT")
  }

  // MARK: - Key command tests

  func testKeyCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "key")
    let response = try CommandResponse(
      ok: true,
      command: "key",
      schemaVersion: "prowl.cli.key.v1",
      data: RawJSON(
        encoding: KeyResponseData(
          requested: KeyResponseRequested(token: "enter", repeat: 1),
          key: KeyResponseKey(normalized: "enter", category: "editing"),
          delivery: KeyResponseDelivery(attempted: 1, delivered: 1, mode: "keyDownUp"),
          target: KeyResponseTarget(
            worktree: ListWorktree(
              id: "Prowl:/Projects/Prowl", name: "Prowl",
              path: "/Projects/Prowl", rootPath: "/Projects/Prowl", kind: "git"
            ),
            tab: KeyResponseTab(id: "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0", title: "Prowl 1", selected: true),
            pane: KeyResponsePane(
              id: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764",
              title: "zsh", cwd: "/Projects/Prowl", focused: true
            )
          )
        ))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["key", "enter", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .key(let input) = envelope.command {
      XCTAssertEqual(input.token, "enter")
      XCTAssertEqual(input.rawToken, "enter")
      XCTAssertEqual(input.repeatCount, 1)
      XCTAssertEqual(input.selector, .none)
    } else {
      XCTFail("Expected key command envelope")
    }

    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, true)
    XCTAssertEqual(payload["command"] as? String, "key")
    XCTAssertEqual(payload["schema_version"] as? String, "prowl.cli.key.v1")
    let data = try XCTUnwrap(payload["data"] as? [String: Any])
    let key = try XCTUnwrap(data["key"] as? [String: Any])
    XCTAssertEqual(key["normalized"] as? String, "enter")
    XCTAssertEqual(key["category"] as? String, "editing")
  }

  func testKeyCommandAliasNormalization() throws {
    let socketPath = temporarySocketPath(suffix: "key-alias")
    let response = CommandResponse(
      ok: true,
      command: "key",
      schemaVersion: "prowl.cli.key.v1"
    )

    let (requestData, _) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["key", "return", "--json"]
    )

    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .key(let input) = envelope.command {
      XCTAssertEqual(input.token, "enter", "Alias 'return' should normalize to 'enter'")
      XCTAssertEqual(input.rawToken, "return", "rawToken should preserve original input")
    } else {
      XCTFail("Expected key command envelope")
    }
  }

  func testKeyCommandCtrlAliasNormalization() throws {
    let socketPath = temporarySocketPath(suffix: "key-ctrl-alias")
    let response = CommandResponse(
      ok: true,
      command: "key",
      schemaVersion: "prowl.cli.key.v1"
    )

    let (requestData, _) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["key", "ctrl+c", "--json"]
    )

    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .key(let input) = envelope.command {
      XCTAssertEqual(input.token, "ctrl-c", "Alias 'ctrl+c' should normalize to 'ctrl-c'")
      XCTAssertEqual(input.rawToken, "ctrl+c")
    } else {
      XCTFail("Expected key command envelope")
    }
  }

  func testKeyCommandCaseInsensitive() throws {
    let socketPath = temporarySocketPath(suffix: "key-case")
    let response = CommandResponse(
      ok: true,
      command: "key",
      schemaVersion: "prowl.cli.key.v1"
    )

    let (requestData, _) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["key", "ENTER", "--json"]
    )

    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .key(let input) = envelope.command {
      XCTAssertEqual(input.token, "enter", "Token parsing should be case-insensitive")
    } else {
      XCTFail("Expected key command envelope")
    }
  }

  func testKeyCommandWithRepeatAndSelector() throws {
    let socketPath = temporarySocketPath(suffix: "key-repeat")
    let response = CommandResponse(
      ok: true,
      command: "key",
      schemaVersion: "prowl.cli.key.v1"
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["key", "--pane", "pane-abc", "up", "--repeat", "5", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .key(let input) = envelope.command {
      XCTAssertEqual(input.token, "up")
      XCTAssertEqual(input.repeatCount, 5)
      XCTAssertEqual(input.selector, .pane("pane-abc"))
    } else {
      XCTFail("Expected key command envelope")
    }
  }

  func testKeyCommandRejectInvalidRepeatZero() throws {
    let result = try runProwl(args: ["key", "enter", "--repeat", "0", "--json"])
    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "key")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidRepeat)
  }

  func testKeyCommandRejectInvalidRepeatOver100() throws {
    let result = try runProwl(args: ["key", "enter", "--repeat", "101", "--json"])
    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidRepeat)
  }

  func testKeyCommandRejectUnsupportedKey() throws {
    let result = try runProwl(args: ["key", "hyper-k", "--json"])
    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "key")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.unsupportedKey)
  }

  func testKeyCommandRejectMultipleSelectors() throws {
    let result = try runProwl(args: ["key", "enter", "--worktree", "Prowl", "--pane", "pane-123", "--json"])
    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "key")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testKeyCommandTextRenderingFromSocket() throws {
    let socketPath = temporarySocketPath(suffix: "key-text")
    let response = try CommandResponse(
      ok: true,
      command: "key",
      schemaVersion: "prowl.cli.key.v1",
      data: RawJSON(
        encoding: KeyResponseData(
          requested: KeyResponseRequested(token: "Ctrl+C", repeat: 3),
          key: KeyResponseKey(normalized: "ctrl-c", category: "control"),
          delivery: KeyResponseDelivery(attempted: 3, delivered: 3, mode: "keyDownUp"),
          target: KeyResponseTarget(
            worktree: ListWorktree(
              id: "Prowl:/Projects/Prowl", name: "Prowl",
              path: "/Projects/Prowl", rootPath: "/Projects/Prowl", kind: "git"
            ),
            tab: KeyResponseTab(id: "t1", title: "Prowl 1", selected: true),
            pane: KeyResponsePane(id: "p1", title: "Claude", cwd: "/Projects/Prowl", focused: true)
          )
        ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["key", "ctrl+c", "--repeat", "3"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Key sent to"), "Missing header: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Prowl:Prowl"), "Missing worktree: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Claude"), "Missing pane title: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("token:"), "Missing token label: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("ctrl-c"), "Missing normalized token: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("category:"), "Missing category label: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("control"), "Missing category value: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("repeat:"), "Missing repeat label: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("delivered:"), "Missing delivered label: \(result.stdout)")
  }

  func testKeyCommandNoColorProducesCleanOutput() throws {
    let socketPath = temporarySocketPath(suffix: "key-no-color")
    let response = try CommandResponse(
      ok: true,
      command: "key",
      schemaVersion: "prowl.cli.key.v1",
      data: RawJSON(
        encoding: KeyResponseData(
          requested: KeyResponseRequested(token: "esc", repeat: 1),
          key: KeyResponseKey(normalized: "esc", category: "control"),
          delivery: KeyResponseDelivery(attempted: 1, delivered: 1, mode: "keyDownUp"),
          target: KeyResponseTarget(
            worktree: ListWorktree(
              id: "wt-1", name: "main",
              path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
            ),
            tab: KeyResponseTab(id: "t1", title: "Tab 1", selected: true),
            pane: KeyResponsePane(id: "p1", title: "zsh", cwd: "/Projects/App", focused: true)
          )
        ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["key", "esc", "--no-color"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertFalse(result.stdout.contains("\u{1B}["), "Should not contain ANSI escape codes: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Key sent to"), "Missing header: \(result.stdout)")
  }

  func testKeyCommandAllCanonicalTokensAccepted() throws {
    let canonicalTokens = [
      "enter", "esc", "tab", "backspace",
      "up", "down", "left", "right",
      "pageup", "pagedown", "home", "end",
      "ctrl-c", "ctrl-d", "ctrl-l",
    ]
    for token in canonicalTokens {
      let socketPath = temporarySocketPath(suffix: "key-canonical-\(token)")
      let response = CommandResponse(
        ok: true,
        command: "key",
        schemaVersion: "prowl.cli.key.v1"
      )

      let (requestData, result) = try runWithMockServer(
        socketPath: socketPath,
        response: response,
        args: ["key", token, "--json"]
      )

      XCTAssertEqual(result.exitCode, 0, "Token '\(token)' should be accepted")
      let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
      if case .key(let input) = envelope.command {
        XCTAssertEqual(input.token, token, "Canonical token '\(token)' should pass through unchanged")
      } else {
        XCTFail("Expected key command envelope for token '\(token)'")
      }
    }
  }

  func testKeyCommandAllAliasesNormalize() throws {
    let aliasMap: [(alias: String, canonical: String)] = [
      ("return", "enter"),
      ("escape", "esc"),
      ("arrow-up", "up"),
      ("arrow-down", "down"),
      ("arrow-left", "left"),
      ("arrow-right", "right"),
      ("pgup", "pageup"),
      ("pgdn", "pagedown"),
      ("ctrl+c", "ctrl-c"),
      ("ctrl+d", "ctrl-d"),
      ("ctrl+l", "ctrl-l"),
    ]
    for (alias, canonical) in aliasMap {
      let socketPath = temporarySocketPath(suffix: "key-alias-\(alias)")
      let response = CommandResponse(
        ok: true,
        command: "key",
        schemaVersion: "prowl.cli.key.v1"
      )

      let (requestData, _) = try runWithMockServer(
        socketPath: socketPath,
        response: response,
        args: ["key", alias, "--json"]
      )

      let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
      if case .key(let input) = envelope.command {
        XCTAssertEqual(input.token, canonical, "Alias '\(alias)' should normalize to '\(canonical)'")
        XCTAssertEqual(input.rawToken, alias, "rawToken should preserve '\(alias)'")
      } else {
        XCTFail("Expected key command envelope for alias '\(alias)'")
      }
    }
  }

  func testKeyCommandExpandedTokensAccepted() throws {
    let tokenCases: [(raw: String, normalized: String)] = [
      ("cmd-c", "cmd-c"),
      ("command-shift-k", "cmd-shift-k"),
      ("alt-enter", "opt-enter"),
      ("ctrl-z", "ctrl-z"),
      ("A", "shift-a"),
      ("Ctrl-A", "shift-ctrl-a"),
      ("CTRL-A", "shift-ctrl-a"),
      ("ctrl-left-bracket", "ctrl-left-bracket"),
      ("ctrl-backslash", "ctrl-backslash"),
      ("ctrl-right-bracket", "ctrl-right-bracket"),
      ("ctrl-shift-6", "shift-ctrl-6"),
      ("ctrl-shift-minus", "shift-ctrl-minus"),
      ("deleteforward", "delete-forward"),
      ("f12", "f12"),
      ("[", "left-bracket"),
    ]

    for (raw, normalized) in tokenCases {
      let socketPath = temporarySocketPath(
        suffix: "key-expanded-\(normalized.replacingOccurrences(of: "-", with: "_"))")
      let response = CommandResponse(
        ok: true,
        command: "key",
        schemaVersion: "prowl.cli.key.v1"
      )

      let (requestData, result) = try runWithMockServer(
        socketPath: socketPath,
        response: response,
        args: ["key", raw, "--json"]
      )

      XCTAssertEqual(result.exitCode, 0, "Token '\(raw)' should be accepted")
      let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
      if case .key(let input) = envelope.command {
        XCTAssertEqual(input.token, normalized)
        XCTAssertEqual(input.rawToken, raw)
      } else {
        XCTFail("Expected key command envelope for token '\(raw)'")
      }
    }
  }

  func testKeyCommandRejectsUnsupportedShiftedSymbolLiteral() throws {
    let result = try runProwl(args: ["key", "!", "--json"])
    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "key")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.unsupportedKey)
  }

  // MARK: - Read command tests

  func testReadCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "read")
    let response = try CommandResponse(
      ok: true,
      command: "read",
      schemaVersion: "prowl.cli.read.v1",
      data: RawJSON(
        encoding: ReadResponseData(
          target: ReadResponseTarget(
            worktree: ListWorktree(
              id: "Prowl:/Projects/Prowl",
              name: "Prowl",
              path: "/Projects/Prowl",
              rootPath: "/Projects/Prowl",
              kind: "git"
            ),
            tab: ReadResponseTab(
              id: "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0",
              title: "Prowl 1",
              selected: true
            ),
            pane: ReadResponsePane(
              id: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764",
              title: "zsh",
              cwd: "/Projects/Prowl",
              focused: true
            )
          ),
          mode: "last",
          last: 5,
          source: "scrollback",
          truncated: false,
          lineCount: 5,
          text: "1\n2\n3\n4\n5"
        ))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["read", "--pane", "pane-123", "--last", "5", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .read(let input) = envelope.command {
      XCTAssertEqual(input.selector, .pane("pane-123"))
      XCTAssertEqual(input.last, 5)
      XCTAssertEqual(input.source, .viewport)
    } else {
      XCTFail("Expected read command envelope")
    }

    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, true)
    XCTAssertEqual(payload["command"] as? String, "read")
    XCTAssertEqual(payload["schema_version"] as? String, "prowl.cli.read.v1")
  }

  func testReadDetectionSourcePassesExactSourceToApp() throws {
    let socketPath = temporarySocketPath(suffix: "read-detection")
    let response = try CommandResponse(
      ok: true,
      command: "read",
      schemaVersion: "prowl.cli.read.v1",
      data: RawJSON(
        encoding: ReadResponseData(
          target: ReadResponseTarget(
            worktree: ListWorktree(
              id: "Prowl:/Projects/Prowl",
              name: "Prowl",
              path: "/Projects/Prowl",
              rootPath: "/Projects/Prowl",
              kind: "git"
            ),
            tab: ReadResponseTab(id: "tab-1", title: "Prowl 1", selected: true),
            pane: ReadResponsePane(id: "pane-1", title: "zsh", cwd: "/Projects/Prowl", focused: true)
          ),
          mode: "snapshot",
          last: nil,
          source: "detection",
          truncated: false,
          lineCount: 2,
          text: "active-line-1\nactive-line-2"
        ))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["read", "--source", "detection", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .read(let input) = envelope.command {
      XCTAssertEqual(input.source, .detection)
    } else {
      XCTFail("Expected read command envelope")
    }

    let payload = try jsonObject(from: result.stdout)
    let data = try XCTUnwrap(payload["data"] as? [String: Any])
    XCTAssertEqual(data["source"] as? String, "detection")
  }

  func testReadDetectionSourceRejectsUnhonoredSource() throws {
    let socketPath = temporarySocketPath(suffix: "read-detection-unhonored")
    let response = try CommandResponse(
      ok: true,
      command: "read",
      schemaVersion: "prowl.cli.read.v1",
      data: RawJSON(
        encoding: ReadResponseData(
          target: ReadResponseTarget(
            worktree: ListWorktree(
              id: "Prowl:/Projects/Prowl",
              name: "Prowl",
              path: "/Projects/Prowl",
              rootPath: "/Projects/Prowl",
              kind: "git"
            ),
            tab: ReadResponseTab(id: "tab-1", title: "Prowl 1", selected: true),
            pane: ReadResponsePane(id: "pane-1", title: "zsh", cwd: "/Projects/Prowl", focused: true)
          ),
          mode: "snapshot",
          last: nil,
          source: "screen",
          truncated: false,
          lineCount: 1,
          text: "viewport"
        ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["read", "--source", "detection", "--json"]
    )

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.readFailed)
    XCTAssertTrue((error["message"] as? String)?.contains("did not honor") == true)
  }

  func testReadDetectionSourceRejectsUnhonoredSourceInTextModeWithoutLeakingText() throws {
    let socketPath = temporarySocketPath(suffix: "read-detection-unhonored-text")
    let response = try CommandResponse(
      ok: true,
      command: "read",
      schemaVersion: "prowl.cli.read.v1",
      data: RawJSON(
        encoding: ReadResponseData(
          target: ReadResponseTarget(
            worktree: ListWorktree(
              id: "Prowl:/Projects/Prowl",
              name: "Prowl",
              path: "/Projects/Prowl",
              rootPath: "/Projects/Prowl",
              kind: "git"
            ),
            tab: ReadResponseTab(id: "tab-1", title: "Prowl 1", selected: true),
            pane: ReadResponsePane(id: "pane-1", title: "zsh", cwd: "/Projects/Prowl", focused: true)
          ),
          mode: "snapshot",
          last: nil,
          source: "screen",
          truncated: false,
          lineCount: 1,
          text: "private viewport text"
        ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["read", "--source", "detection"]
    )

    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout, "")
    XCTAssertTrue(result.stderr.contains("error [READ_FAILED]"))
    XCTAssertFalse(result.stderr.contains("private viewport text"))
    XCTAssertEqual(result.stderr.components(separatedBy: "READ_FAILED").count - 1, 1)
  }

  func testReadWithoutLastDefaultsToSnapshot() throws {
    let socketPath = temporarySocketPath(suffix: "read-snapshot")
    let response = CommandResponse(
      ok: true,
      command: "read",
      schemaVersion: "prowl.cli.read.v1"
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["read", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .read(let input) = envelope.command {
      XCTAssertEqual(input.selector, .none)
      XCTAssertNil(input.last)
    } else {
      XCTFail("Expected read command envelope")
    }
  }

  func testReadRejectsInvalidLastBeforeTransport() throws {
    let result = try runProwl(args: ["read", "--last", "0", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "read")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testReadRejectsMultipleSelectorsBeforeTransport() throws {
    let result = try runProwl(args: ["read", "--worktree", "Prowl", "--pane", "pane-123", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "read")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testReadTextRenderingFromSocket() throws {
    let socketPath = temporarySocketPath(suffix: "read-text")
    let response = try CommandResponse(
      ok: true,
      command: "read",
      schemaVersion: "prowl.cli.read.v1",
      data: RawJSON(
        encoding: ReadResponseData(
          target: ReadResponseTarget(
            worktree: ListWorktree(
              id: "wt-1",
              name: "main",
              path: "/Projects/App",
              rootPath: "/Projects/App",
              kind: "git"
            ),
            tab: ReadResponseTab(id: "t1", title: "Tab 1", selected: true),
            pane: ReadResponsePane(id: "p1", title: "zsh", cwd: "/Projects/App", focused: true)
          ),
          mode: "last",
          last: 3,
          source: "scrollback",
          truncated: false,
          lineCount: 3,
          text: "a\nb\nc"
        ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["read"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Read from"), "Missing header: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("mode:"), "Missing mode line: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("source:"), "Missing source line: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("a\nb\nc"), "Missing text body: \(result.stdout)")
  }

  func testReadWaitStablePassesOptionsToEnvelope() throws {
    let socketPath = temporarySocketPath(suffix: "read-wait-stable")
    let response = CommandResponse(
      ok: true,
      command: "read",
      schemaVersion: "prowl.cli.read.v1"
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: [
        "read", "--wait-stable",
        "--stable-interval", "150",
        "--stable-period", "600",
        "--wait-timeout", "5",
        "--json",
      ]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .read(let input) = envelope.command {
      XCTAssertTrue(input.waitStable)
      XCTAssertEqual(input.stableIntervalMs, 150)
      XCTAssertEqual(input.stablePeriodMs, 600)
      XCTAssertEqual(input.waitTimeoutSeconds, 5)
    } else {
      XCTFail("Expected read command envelope")
    }
  }

  func testReadStabilityOptionsRequireWaitStable() throws {
    let result = try runProwl(args: ["read", "--stable-interval", "150", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testReadWaitStableRejectsOutOfRangeInterval() throws {
    let result = try runProwl(args: ["read", "--wait-stable", "--stable-interval", "10", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  // MARK: - Handoff command tests

  func testHandoffSaveRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "handoff-save")
    let response = try CommandResponse(
      ok: true,
      command: "handoff",
      schemaVersion: "prowl.cli.handoff.v2",
      data: RawJSON(encoding: makeHandoffPayload(action: .save))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["handoff", "save", "--worktree", "App", "--note", "wip", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .handoff(let input) = envelope.command {
      XCTAssertEqual(input.action, .save)
      XCTAssertEqual(input.selector, .worktree("App"))
      XCTAssertEqual(input.note, "wip")
      XCTAssertTrue(input.launch)
      XCTAssertNil(input.brief)
      XCTAssertFalse(input.contextOnly)
    } else {
      XCTFail("Expected handoff command envelope")
    }

    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, true)
    XCTAssertEqual(payload["command"] as? String, "handoff")
  }

  func testHandoffToSendsInlineBriefAndContextOnly() throws {
    let socketPath = temporarySocketPath(suffix: "handoff-brief")
    let response = try CommandResponse(
      ok: true,
      command: "handoff",
      schemaVersion: "prowl.cli.handoff.v2",
      data: RawJSON(encoding: makeHandoffPayload(action: .toAgent))
    )

    let brief = "# Handoff\n\n## Objective\nShip.\n\n## Current State\nGreen.\n\n## Next Steps\n1. Go."
    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["handoff", "to", "claude", "--brief", brief, "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .handoff(let input) = envelope.command {
      XCTAssertEqual(input.brief, brief)
      XCTAssertFalse(input.contextOnly)
    } else {
      XCTFail("Expected handoff command envelope")
    }

    let contextOnlySocket = temporarySocketPath(suffix: "handoff-no-brief")
    let (contextOnlyRequest, contextOnlyResult) = try runWithMockServer(
      socketPath: contextOnlySocket,
      response: response,
      args: ["handoff", "to", "claude", "--no-brief", "--json"]
    )
    XCTAssertEqual(contextOnlyResult.exitCode, 0)
    let contextOnlyEnvelope = try JSONDecoder().decode(CommandEnvelope.self, from: contextOnlyRequest)
    if case .handoff(let input) = contextOnlyEnvelope.command {
      XCTAssertNil(input.brief)
      XCTAssertTrue(input.contextOnly)
    } else {
      XCTFail("Expected handoff command envelope")
    }
  }

  func testHandoffBriefConflictFailsBeforeTransport() throws {
    let result = try runProwl(args: ["handoff", "to", "claude", "--brief", "x", "--no-brief", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testHandoffToRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "handoff-to")
    let response = try CommandResponse(
      ok: true,
      command: "handoff",
      schemaVersion: "prowl.cli.handoff.v2",
      data: RawJSON(encoding: makeHandoffPayload(action: .toAgent))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["handoff", "to", "claude", "--pane", "p1", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .handoff(let input) = envelope.command {
      XCTAssertEqual(input.action, .toAgent)
      XCTAssertEqual(input.toAgent, "claude")
      XCTAssertEqual(input.selector, .pane("p1"))
      XCTAssertTrue(input.launch)
    } else {
      XCTFail("Expected handoff command envelope")
    }
  }

  func testHandoffToNormalizesAgentCaseAndNoLaunch() throws {
    let socketPath = temporarySocketPath(suffix: "handoff-to-no-launch")
    let response = try CommandResponse(
      ok: true,
      command: "handoff",
      schemaVersion: "prowl.cli.handoff.v2",
      data: RawJSON(encoding: makeHandoffPayload(action: .toAgent))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["handoff", "to", "CODEX", "--no-launch", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .handoff(let input) = envelope.command {
      XCTAssertEqual(input.toAgent, "codex")
      XCTAssertFalse(input.launch)
    } else {
      XCTFail("Expected handoff command envelope")
    }
  }

  func testHandoffToAcceptsDetectedAgentToken() throws {
    let socketPath = temporarySocketPath(suffix: "handoff-to-gemini")
    let response = try CommandResponse(
      ok: true,
      command: "handoff",
      schemaVersion: "prowl.cli.handoff.v2",
      data: RawJSON(encoding: makeHandoffPayload(action: .toAgent))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["handoff", "to", "gemini", "--no-launch", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .handoff(let input) = envelope.command {
      XCTAssertEqual(input.toAgent, "gemini")
      XCTAssertFalse(input.launch)
    } else {
      XCTFail("Expected handoff command envelope")
    }
  }

  func testHandoffToRejectsUnknownAgentBeforeTransport() throws {
    let result = try runProwl(args: ["handoff", "to", "unknown-agent", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "handoff")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testHandoffToTextRenderingFromSocket() throws {
    let socketPath = temporarySocketPath(suffix: "handoff-to-text")
    let response = try CommandResponse(
      ok: true,
      command: "handoff",
      schemaVersion: "prowl.cli.handoff.v2",
      data: RawJSON(
        encoding: HandoffCommandPayload(
          action: .toAgent,
          artifactPath: "/Projects/App/.prowl/handoff/current.md",
          outgoingAgent: "codex",
          toAgent: "claude",
          repos: [
            HandoffRepoPayload(
              name: "App", branch: "feature", isGit: true, changedFileCount: 3, insertions: 120, deletions: 14)
          ],
          changedFileCount: 3,
          archivedPath: "handoff/archive/2026-06-12T1430-codex-to-claude.md",
          sessionContext: HandoffSessionPayload(
            agent: "codex",
            sessionID: "codex-session",
            paneID: "pane-0",
            paneTitle: "codex",
            source: "terminal-scrollback",
            confidence: "fallback",
            excerptPath: "handoff/sessions/2026-06-12T1430-pane-0.md",
            transcriptPath: "/tmp/codex.jsonl"
          ),
          briefing: "inline",
          hasBriefing: true,
          launchedPane: HandoffPanePayload(
            worktreeID: "App:/Projects/App",
            worktreeName: "App",
            tabID: "tab-1",
            paneID: "pane-9",
            paneTitle: "claude"
          )
        ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["handoff", "to", "claude"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("codex → claude"), "Missing transition header: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("artifact:"), "Missing artifact line: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("briefing:"), "Missing briefing line: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("session:"), "Missing session line: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("launched:"), "Missing launched line: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("pane-9"), "Missing launched pane id: \(result.stdout)")
  }

  func testHandoffToWithoutLaunchTextExplainsExistingFlag() throws {
    let socketPath = temporarySocketPath(suffix: "handoff-to-no-launch-text")
    let response = try CommandResponse(
      ok: true,
      command: "handoff",
      schemaVersion: "prowl.cli.handoff.v2",
      data: RawJSON(
        encoding: HandoffCommandPayload(
          action: .toAgent,
          artifactPath: "/Projects/App/.prowl/handoff/current.md",
          outgoingAgent: "codex",
          toAgent: "claude",
          archivedPath: "handoff/archive/2026-06-12T1430-codex-to-claude.md"
        ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["handoff", "to", "claude", "--no-launch"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("no (--no-launch); take over manually"), result.stdout)
    XCTAssertFalse(result.stdout.contains("use --no-launch handoff"), result.stdout)
  }

  // MARK: - Helpers

  private func makeHandoffPayload(action: HandoffAction) -> HandoffCommandPayload {
    HandoffCommandPayload(
      action: action,
      artifactPath: "/Projects/App/.prowl/handoff/current.md",
      outgoingAgent: "codex",
      toAgent: action == .toAgent ? "claude" : nil,
      repos: [
        HandoffRepoPayload(name: "App", branch: "main", isGit: true, changedFileCount: 1, insertions: 8, deletions: 2)
      ],
      changedFileCount: 1
    )
  }

  private func runWithMockServer(
    socketPath: String,
    response: CommandResponse,
    args: [String],
    stdinData: Data? = nil,
    environment: [String: String] = [:]
  ) throws -> (Data, CommandResult) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let responseData = try encoder.encode(response)
    return try runWithMockServer(
      socketPath: socketPath,
      responseData: responseData,
      args: args,
      stdinData: stdinData,
      environment: environment
    )
  }

  private func runWithMockServer(
    socketPath: String,
    responseData: Data,
    args: [String],
    stdinData: Data? = nil,
    environment: [String: String] = [:]
  ) throws -> (Data, CommandResult) {
    try assertResponseMatchesSchema(responseData)
    let server = try MockSocketServer(socketPath: socketPath, responseData: responseData)
    defer { server.stop() }
    try server.start()

    var requestEnvironment = environment
    requestEnvironment[ProwlSocket.environmentKey] = socketPath
    let result = try runProwl(args: args, environment: requestEnvironment, stdinData: stdinData)

    let requestData = try XCTUnwrap(server.waitForRequest(timeout: 2.0), "No request received by mock server")
    return (requestData, result)
  }

  private func assertResponseMatchesSchema(_ responseData: Data) throws {
    let response = try JSONDecoder().decode(CommandResponse.self, from: responseData)
    guard response.data != nil || response.ok == false else { return }

    let schemaText = try XCTUnwrap(String(data: ProwlCLIContractBundle.schemaData, encoding: .utf8))
    let responseText = try XCTUnwrap(String(data: responseData, encoding: .utf8))
    let schema = try Schema(instance: schemaText)
    let result = try schema.validate(instance: responseText)
    XCTAssertTrue(
      result.isValid,
      "Socket response violates JSON Schema for \(response.command) \(response.schemaVersion)."
    )
  }

  private func makeLifecyclePayload(
    resource: LifecycleResource,
    anchor: TabTarget? = nil,
    direction: CreatePaneDirection? = nil,
    launch: LifecycleCommandLaunch? = nil,
    dispatch: DispatchPendingRecord? = nil,
    warnings: [LifecycleCommandWarning]? = nil
  ) -> LifecycleCommandPayload {
    LifecycleCommandPayload(
      resource: resource,
      anchor: anchor,
      direction: direction,
      launch: launch,
      dispatch: dispatch,
      warnings: warnings,
      target: makeTabTarget()
    )
  }

  private func makeTabPayload(action: TabAction) -> TabCommandPayload {
    TabCommandPayload(action: action, target: makeTabTarget())
  }

  private func makePanePayload(action: PaneAction) -> PaneCommandPayload {
    PaneCommandPayload(action: action, target: makeTabTarget())
  }

  private func makeAgentResponse(
    id: String,
    handle: Int? = nil,
    name: String,
    status: String,
    projectName: String,
    branch: String,
    tabTitle: String,
    detectionReason: String? = nil,
    session: AgentsResponseSession? = nil
  ) -> AgentsResponseAgent {
    AgentsResponseAgent(
      id: id,
      type: name,
      name: name,
      status: status,
      rawState: status,
      detectionReason: detectionReason,
      lastChangedAt: "2026-06-13T04:12:25Z",
      project: AgentsResponseProject(name: projectName, branch: branch, path: "/Projects/\(projectName)"),
      worktree: ListWorktree(
        id: "\(projectName):/Projects/\(projectName)",
        name: branch,
        path: "/Projects/\(projectName)",
        rootPath: "/Projects/\(projectName)",
        kind: "git"
      ),
      tab: ListTab(id: "\(id)-tab", title: tabTitle, selected: true),
      pane: AgentsResponsePane(
        id: id,
        handle: handle,
        index: 1,
        title: name,
        cwd: "/Projects/\(projectName)",
        focused: false
      ),
      session: session
    )
  }

  private func makeTabTarget(paneID: String = "pane-123") -> TabTarget {
    TabTarget(
      worktree: TabTargetWorktree(
        id: "App:/Projects/App",
        name: "App",
        path: "/Projects/App",
        rootPath: "/Projects/App",
        kind: "git"
      ),
      tab: TabTargetTab(id: "tab-123", title: "App 1", selected: true),
      pane: TabTargetPane(id: paneID, title: "zsh", cwd: "/Projects/App", focused: true)
    )
  }

  private func runProwl(
    args: [String],
    environment: [String: String] = [:],
    stdinData: Data? = nil
  ) throws -> CommandResult {
    let binaryPath = try ensureProwlBinary()
    var mergedEnvironment = ProcessInfo.processInfo.environment
    for (key, value) in environment {
      mergedEnvironment[key] = value
    }
    return try runProcess(
      executable: binaryPath,
      arguments: args,
      currentDirectory: repoRoot.path,
      environment: mergedEnvironment,
      stdinData: stdinData
    )
  }

  private func runProwlWithDefaultSIGPIPE(
    args: [String],
    environment: [String: String],
    stdinData: Data
  ) throws -> CommandResult {
    let binaryPath = try ensureProwlBinary()
    var mergedEnvironment = ProcessInfo.processInfo.environment
    for (key, value) in environment {
      mergedEnvironment[key] = value
    }
    return try runProcess(
      executable: "/bin/sh",
      arguments: ["-c", "trap - PIPE; exec \"$@\"", "sh", binaryPath] + args,
      currentDirectory: repoRoot.path,
      environment: mergedEnvironment,
      stdinData: stdinData
    )
  }

  private func ensureProwlBinary() throws -> String {
    let candidates = [
      repoRoot.appendingPathComponent(".build/debug/prowl").path,
      repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/prowl").path,
      repoRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/prowl").path,
    ]

    if let existing = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
      return existing
    }

    throw NSError(
      domain: "ProwlCLITests",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "Could not find prowl binary. Checked: \(candidates.joined(separator: ", "))"
      ]
    )
  }

  private func runProcess(
    executable: String,
    arguments: [String],
    currentDirectory: String,
    environment: [String: String]? = nil,
    stdinData: Data? = nil
  ) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
    if let environment {
      process.environment = environment
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    if let stdinData {
      let stdinPipe = Pipe()
      process.standardInput = stdinPipe
      stdinPipe.fileHandleForWriting.write(stdinData)
      stdinPipe.fileHandleForWriting.closeFile()
    } else {
      // Use /dev/null so isatty(stdin) doesn't incorrectly report stdin data.
      process.standardInput = FileHandle.nullDevice
    }

    try process.run()
    process.waitUntilExit()

    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
  }

  private func jsonObject(from text: String) throws -> [String: Any] {
    let data = try XCTUnwrap(text.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func assertNoRawJSONControlCharacters(
    in text: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let data = text.data(using: .utf8) else {
      XCTFail("Output is not UTF-8", file: file, line: line)
      return
    }

    for byte in data where byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D {
      XCTFail("Output contains raw control byte 0x\(String(byte, radix: 16))", file: file, line: line)
    }
  }

  /// Directory for mock-server socket files, kept deliberately short. AF_UNIX
  /// `sun_path` is capped at ~104 bytes; `NSTemporaryDirectory()` alone is ~49,
  /// so `prowl-cli-<suffix>-<uuid>.sock` overflows and `bind()` silently
  /// truncates the path. A truncated path would not match the string we pass to
  /// `unlink()`, leaking the socket file. `/tmp` keeps the full path well under
  /// the limit (and matches the CLI's own socket convention).
  private static let socketDirectory = "/tmp"

  private func temporarySocketPath(suffix: String) -> String {
    let uuid = UUID().uuidString.lowercased()
    let filename = "prowl-cli-\(suffix)-\(uuid).sock"
    let path = (Self.socketDirectory as NSString).appendingPathComponent(filename)
    // Fail fast if a future suffix pushes the path past the sun_path limit,
    // rather than letting bind() truncate and leak the socket again.
    precondition(path.utf8.count <= 103, "Socket path exceeds AF_UNIX sun_path limit: \(path)")
    return path
  }
}

private struct OpenResponseData: Encodable {
  let invocation: String
  let requestedPath: String?
  let resolvedPath: String?
  let resolution: String
  let appLaunched: Bool

  enum CodingKeys: String, CodingKey {
    case invocation
    case requestedPath = "requested_path"
    case resolvedPath = "resolved_path"
    case resolution
    case appLaunched = "app_launched"
    case broughtToFront = "brought_to_front"
    case createdTab = "created_tab"
    case target
  }

  let broughtToFront: Bool
  let createdTab = false
  let target: OpenResponseTarget? = nil

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(invocation, forKey: .invocation)
    try container.encode(requestedPath, forKey: .requestedPath)
    try container.encode(resolvedPath, forKey: .resolvedPath)
    try container.encode(resolution, forKey: .resolution)
    try container.encode(appLaunched, forKey: .appLaunched)
    try container.encode(broughtToFront, forKey: .broughtToFront)
    try container.encode(createdTab, forKey: .createdTab)
    try container.encode(target, forKey: .target)
  }
}

private struct OpenResponseTarget: Encodable {
  let worktree: ListWorktree
  let tab: OpenResponseTab
  let pane: OpenResponsePane
}

private struct OpenResponseTab: Encodable {
  let id: String
  let title: String
  let cwd: String?
}

private struct OpenResponsePane: Encodable {
  let id: String
  let title: String
  let cwd: String?
}

private struct ListResponseData: Encodable {
  let count: Int
  let items: [ListResponseItem]
}

private struct ListResponseItem: Encodable {
  let worktree: ListWorktree
  let tab: ListTab
  let pane: ListPane
  let task: ListTask
}

private struct ListWorktree: Encodable {
  let id: String
  let name: String
  let path: String

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case path
    case rootPath = "root_path"
    case kind
  }

  let rootPath: String
  let kind: String
}

private struct ListTab: Encodable {
  let id: String
  let handle: Int?
  let title: String
  let selected: Bool

  init(id: String, handle: Int? = nil, title: String, selected: Bool) {
    self.id = id
    self.handle = handle
    self.title = title
    self.selected = selected
  }
}

private struct ListPane: Encodable {
  let id: String
  let handle: Int?
  let title: String
  let cwd: String?
  let focused: Bool
  let agent: String?

  init(
    id: String,
    handle: Int? = nil,
    title: String,
    cwd: String?,
    focused: Bool,
    agent: String? = nil
  ) {
    self.id = id
    self.handle = handle
    self.title = title
    self.cwd = cwd
    self.focused = focused
    self.agent = agent
  }
}

private struct ListTask: Encodable {
  let status: String?
}

private struct AgentsResponseData: Encodable {
  let count: Int
  let agents: [AgentsResponseAgent]
}

private struct AgentsResponseAgent: Encodable {
  let id: String
  let type: String
  let name: String
  let status: String

  enum CodingKeys: String, CodingKey {
    case id
    case type
    case name
    case status
    case rawState = "raw_state"
    case detectionReason = "detection_reason"
    case lastChangedAt = "last_changed_at"
    case project
    case worktree
    case tab
    case pane
    case session
  }

  let rawState: String
  let detectionReason: String?
  let lastChangedAt: String
  let project: AgentsResponseProject
  let worktree: ListWorktree
  let tab: ListTab
  let pane: AgentsResponsePane
  let session: AgentsResponseSession?
}

private struct AgentsResponseSession: Encodable {
  let id: String
  let path: String?
  let confidence: String
  let source: String
}

private struct AgentsResponseProject: Encodable {
  let name: String
  let branch: String
  let path: String
}

private struct AgentsResponsePane: Encodable {
  let id: String
  let handle: Int?
  let index: Int
  let title: String
  let cwd: String?
  let focused: Bool

  init(id: String, handle: Int? = nil, index: Int, title: String, cwd: String?, focused: Bool) {
    self.id = id
    self.handle = handle
    self.index = index
    self.title = title
    self.cwd = cwd
    self.focused = focused
  }
}

private struct FocusResponseData: Encodable {
  let requested: FocusRequested

  enum CodingKeys: String, CodingKey {
    case requested
    case resolvedVia = "resolved_via"
    case broughtToFront = "brought_to_front"
    case target
  }

  let resolvedVia: String
  let broughtToFront: Bool
  let target: FocusResponseTarget
}

private struct FocusRequested: Encodable {
  let selector: String
  let value: String?
}

private struct FocusResponseTarget: Encodable {
  let worktree: ListWorktree
  let tab: FocusResponseTab
  let pane: FocusResponsePane
}

private struct FocusResponseTab: Encodable {
  let id: String
  let title: String
  let selected: Bool
}

private struct FocusResponsePane: Encodable {
  let id: String
  let title: String
  let cwd: String?
  let focused: Bool
}

private struct SendResponseData: Encodable {
  let target: SendResponseTarget
  let input: SendResponseInput

  enum CodingKeys: String, CodingKey {
    case target
    case input
    case createdTab = "created_tab"
    case wait
  }

  let createdTab: Bool
  let wait: SendResponseWait?

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(target, forKey: .target)
    try container.encode(input, forKey: .input)
    try container.encode(createdTab, forKey: .createdTab)
    if let wait {
      try container.encode(wait, forKey: .wait)
    } else {
      try container.encodeNil(forKey: .wait)
    }
  }
}

private struct SendResponseTarget: Encodable {
  let worktree: ListWorktree
  let tab: SendResponseTab
  let pane: SendResponsePane
}

private struct SendResponseTab: Encodable {
  let id: String
  let title: String
  let selected: Bool
}

private struct SendResponsePane: Encodable {
  let id: String
  let title: String
  let cwd: String?
  let focused: Bool
}

private struct SendResponseInput: Encodable {
  let source: String
  let characters: Int
  let bytes: Int

  enum CodingKeys: String, CodingKey {
    case source
    case characters
    case bytes
    case trailingEnterSent = "trailing_enter_sent"
  }

  let trailingEnterSent: Bool

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(source, forKey: .source)
    try container.encode(characters, forKey: .characters)
    try container.encode(bytes, forKey: .bytes)
    try container.encode(trailingEnterSent, forKey: .trailingEnterSent)
  }
}

private struct SendResponseWait: Encodable {
  let exitCode: Int?
  let durationMs: Int

  enum CodingKeys: String, CodingKey {
    case exitCode = "exit_code"
    case durationMs = "duration_ms"
  }
}

private struct KeyResponseData: Encodable {
  let requested: KeyResponseRequested
  let key: KeyResponseKey
  let delivery: KeyResponseDelivery
  let target: KeyResponseTarget
}

private struct KeyResponseRequested: Encodable {
  let token: String
  let `repeat`: Int
}

private struct KeyResponseKey: Encodable {
  let normalized: String
  let category: String
}

private struct KeyResponseDelivery: Encodable {
  let attempted: Int
  let delivered: Int
  let mode: String
}

private struct KeyResponseTarget: Encodable {
  let worktree: ListWorktree
  let tab: KeyResponseTab
  let pane: KeyResponsePane
}

private struct KeyResponseTab: Encodable {
  let id: String
  let title: String
  let selected: Bool
}

private struct KeyResponsePane: Encodable {
  let id: String
  let title: String
  let cwd: String?
  let focused: Bool
}

private struct ReadResponseData: Encodable {
  let target: ReadResponseTarget
  let mode: String
  let last: Int?
  let source: String
  let truncated: Bool

  enum CodingKeys: String, CodingKey {
    case target
    case mode
    case last
    case source
    case truncated
    case lineCount = "line_count"
    case text
  }

  let lineCount: Int
  let text: String
}

private struct ReadResponseTarget: Encodable {
  let worktree: ListWorktree
  let tab: ReadResponseTab
  let pane: ReadResponsePane
}

private struct ReadResponseTab: Encodable {
  let id: String
  let title: String
  let selected: Bool
}

private struct ReadResponsePane: Encodable {
  let id: String
  let title: String
  let cwd: String?
  let focused: Bool
}

private struct CommandResult {
  let exitCode: Int32
  let stdout: String
  let stderr: String
}

private final class MockSocketServer: @unchecked Sendable {
  private let socketPath: String
  private let responseData: Data
  private let responseByteDelayMicroseconds: useconds_t
  private let closesAfterRequestLength: Bool

  private var serverFD: Int32 = -1
  private var receivedRequestData: Data?
  private let lock = NSLock()
  private let requestSemaphore = DispatchSemaphore(value: 0)

  init(
    socketPath: String,
    responseData: Data,
    responseByteDelayMicroseconds: useconds_t = 0,
    closesAfterRequestLength: Bool = false
  ) throws {
    self.socketPath = socketPath
    self.responseData = responseData
    self.responseByteDelayMicroseconds = responseByteDelayMicroseconds
    self.closesAfterRequestLength = closesAfterRequestLength
  }

  deinit { stop() }

  /// Idempotent teardown: closes the listening socket and removes its file.
  /// Invoked via `defer` from the test helper so cleanup does not rely on
  /// non-deterministic `deinit` timing — the accept loop runs on a background
  /// queue, which can delay ARC release and leave the bound socket file behind.
  func stop() {
    if serverFD >= 0 {
      close(serverFD)
      serverFD = -1
    }
    unlink(socketPath)
  }

  func start() throws {
    unlink(socketPath)

    serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard serverFD >= 0 else {
      throw MockSocketError.socketCreateFailed
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)

    let pathBytes = Array(socketPath.utf8)
    let maxLength = MemoryLayout.size(ofValue: addr.sun_path) - 1
    let copyLength = min(pathBytes.count, maxLength)

    withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
      for index in 0..<copyLength {
        buffer[index] = pathBytes[index]
      }
      buffer[copyLength] = 0
    }

    let bindResult = withUnsafePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPointer in
        bind(serverFD, addrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }

    guard bindResult == 0 else {
      throw MockSocketError.bindFailed
    }

    guard listen(serverFD, 1) == 0 else {
      throw MockSocketError.listenFailed
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let clientFD = accept(self.serverFD, nil, nil)
      guard clientFD >= 0 else { return }
      defer { close(clientFD) }
      var noSigPipe: Int32 = 1
      _ = withUnsafePointer(to: &noSigPipe) {
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
      }

      do {
        let lengthData = try self.readExact(fd: clientFD, count: 4)
        if self.closesAfterRequestLength {
          self.requestSemaphore.signal()
          return
        }
        let bodyLength = lengthData.withUnsafeBytes {
          UInt32(bigEndian: $0.load(as: UInt32.self))
        }
        let body = try self.readExact(fd: clientFD, count: Int(bodyLength))

        self.lock.lock()
        self.receivedRequestData = body
        self.lock.unlock()
        self.requestSemaphore.signal()

        var responseLength = UInt32(self.responseData.count).bigEndian
        try withUnsafeBytes(of: &responseLength) { lengthBytes in
          try self.writeAll(fd: clientFD, bytes: lengthBytes)
        }
        if self.responseByteDelayMicroseconds == 0 {
          try self.responseData.withUnsafeBytes { bytes in
            try self.writeAll(fd: clientFD, bytes: bytes)
          }
        } else {
          for byte in self.responseData {
            var value = byte
            try withUnsafeBytes(of: &value) { try self.writeAll(fd: clientFD, bytes: $0) }
            usleep(self.responseByteDelayMicroseconds)
          }
        }
      } catch {
        self.requestSemaphore.signal()
      }
    }
  }

  func waitForRequest(timeout: TimeInterval) -> Data? {
    let result = requestSemaphore.wait(timeout: .now() + timeout)
    guard result == .success else { return nil }

    lock.lock()
    defer { lock.unlock() }
    return receivedRequestData
  }

  private func readExact(fd: Int32, count: Int) throws -> Data {
    var data = Data(capacity: count)
    var remaining = count
    let bufferSize = min(count, 65536)
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
    defer { buffer.deallocate() }

    while remaining > 0 {
      let toRead = min(remaining, bufferSize)
      let readCount = Darwin.read(fd, buffer, toRead)
      guard readCount > 0 else {
        throw MockSocketError.readFailed
      }
      data.append(buffer.assumingMemoryBound(to: UInt8.self), count: readCount)
      remaining -= readCount
    }

    return data
  }

  private func writeAll(fd: Int32, bytes: UnsafeRawBufferPointer) throws {
    var offset = 0
    while offset < bytes.count {
      let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
      guard written > 0 else {
        throw MockSocketError.writeFailed
      }
      offset += written
    }
  }
}

private enum MockSocketError: Error {
  case socketCreateFailed
  case bindFailed
  case listenFailed
  case readFailed
  case writeFailed
}

private final class PermissionDeniedSocket {
  private let socketPath: String
  private var serverFD: Int32 = -1

  init(socketPath: String) {
    self.socketPath = socketPath
  }

  deinit { stop() }

  func start() throws {
    unlink(socketPath)
    serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard serverFD >= 0 else {
      throw MockSocketError.socketCreateFailed
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    let maxLength = MemoryLayout.size(ofValue: addr.sun_path) - 1
    let copyLength = min(pathBytes.count, maxLength)
    withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
      for index in 0..<copyLength {
        buffer[index] = pathBytes[index]
      }
      buffer[copyLength] = 0
    }

    let bindResult = withUnsafePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPointer in
        bind(serverFD, addrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else {
      throw MockSocketError.bindFailed
    }
    guard listen(serverFD, 1) == 0 else {
      throw MockSocketError.listenFailed
    }
    guard chmod(socketPath, 0) == 0 else {
      throw MockSocketError.bindFailed
    }
  }

  func stop() {
    if serverFD >= 0 {
      close(serverFD)
      serverFD = -1
    }
    chmod(socketPath, S_IRUSR | S_IWUSR)
    unlink(socketPath)
  }
}
