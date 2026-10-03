import Foundation
import ProwlCLIContracts
import ProwlCLIShared
import XCTest

@testable import prowl

final class AgentsCommandParsingTests: XCTestCase {
  func testListParsesWithoutSubcommand() throws {
    _ = try AgentsCommand.parse([])
  }

  func testReadParsesExplicitPaneAndResultOptions() throws {
    let command = try AgentsReadCommand.parse(["p7", "--max-bytes", "1024", "--result-only"])

    XCTAssertEqual(command.pane, "p7")
    XCTAssertEqual(command.maxBytes, 1024)
    XCTAssertTrue(command.resultOnly)
  }

  func testReadRequiresPaneHandleOrUUID() {
    XCTAssertThrowsError(try AgentsReadCommand.parse(["main"]))
  }

  func testReadRejectsResultOnlyJSONCombination() throws {
    let command = try AgentsReadCommand.parse(["p7", "--result-only", "--json"])

    XCTAssertThrowsError(try command.validateOutputMode())
  }

  func testSignalParsesEventAndMetadata() throws {
    let command = try AgentsSignalCommand.parse([
      "turn-ended",
      "--origin", "manual-review",
      "--session", "session-1",
      "--detail", "Review complete",
      "--json",
    ])

    XCTAssertEqual(command.event, .turnEnded)
    XCTAssertNil(command.progress)
    XCTAssertEqual(command.origin, "manual-review")
    XCTAssertEqual(command.sessionID, "session-1")
    XCTAssertEqual(command.detail, "Review complete")
    XCTAssertTrue(command.options.json)
  }

  func testSignalParsesIndeterminateAndNumericProgress() throws {
    let indeterminate = try AgentsSignalCommand.parse(["progress"])
    let numeric = try AgentsSignalCommand.parse(["progress", "--progress", "75"])

    XCTAssertEqual(indeterminate.event, .progress)
    XCTAssertNil(indeterminate.progress)
    XCTAssertEqual(numeric.progress, 75)
  }

  func testSignalHelpAndSchemaUseSharedDetailLimit() throws {
    XCTAssertTrue(
      AgentsSignalCommand.helpMessage().contains(
        "maximum \(AgentSignalInput.maximumDetailBytes) UTF-8 bytes"
      )
    )

    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: ProwlCLIContractBundle.schemaData) as? [String: Any]
    )
    let definitions = try XCTUnwrap(root["$defs"] as? [String: Any])
    let agentSignalData = try XCTUnwrap(definitions["agentSignalData"] as? [String: Any])
    let dataProperties = try XCTUnwrap(agentSignalData["properties"] as? [String: Any])
    let signal = try XCTUnwrap(dataProperties["signal"] as? [String: Any])
    let signalProperties = try XCTUnwrap(signal["properties"] as? [String: Any])
    let detail = try XCTUnwrap(signalProperties["detail"] as? [String: Any])

    XCTAssertEqual(detail["maxLength"] as? Int, AgentSignalInput.maximumDetailBytes)
  }

  func testSignalRejectsInvalidEventProgressAndBoundedText() {
    XCTAssertThrowsError(try AgentsSignalCommand.parse(["complete"]))
    XCTAssertThrowsError(try AgentsSignalCommand.parse(["turn-ended", "--progress", "1"]))
    XCTAssertThrowsError(try AgentsSignalCommand.parse(["progress", "--progress", "101"]))
    XCTAssertNoThrow(
      try AgentsSignalCommand.parse(["needs-input", "--detail", String(repeating: "x", count: 32_768)])
    )
    XCTAssertNoThrow(
      try AgentsSignalCommand.parse(["needs-input", "--detail", String(repeating: "界", count: 10_922)])
    )
    XCTAssertThrowsError(
      try AgentsSignalCommand.parse(["needs-input", "--detail", String(repeating: "x", count: 32_769)])
    )
    XCTAssertThrowsError(
      try AgentsSignalCommand.parse(["needs-input", "--detail", String(repeating: "界", count: 10_923)])
    )
  }

  func testRelayedRuntimesReadNativeEventPayloadsFromStdin() throws {
    let cases: [(String, String, AgentNativeHookRuntime, AgentSignalEvent)] = [
      ("pi", "agent_settled", .pi, .turnEnded),
      ("omp", "session_switch", .omp, .sessionStart),
      ("opencode", "permission.asked", .opencode, .needsInput),
    ]
    for (runtimeName, nativeEvent, runtime, event) in cases {
      let command = try AgentsHookCommand.parse([runtimeName, nativeEvent])
      let input = try command.makeInput(
        environment: [AgentNativeHookInput.tokenEnvironmentKey: "token-1"],
        stdin: Data(
          #"{"hook_event_name":"\#(nativeEvent)","session_id":"s-1","cwd":"/tmp/project","reason":"edit"}"#.utf8
        )
      )
      XCTAssertEqual(input.runtime, runtime)
      XCTAssertEqual(input.signal.event, event)
      XCTAssertEqual(input.signal.nativeEvent, nativeEvent)
      XCTAssertEqual(input.signal.sessionID, "s-1")
      XCTAssertThrowsError(
        try AgentsHookCommand.parse([runtimeName, nativeEvent, "{}"]).makeInput(
          environment: [AgentNativeHookInput.tokenEnvironmentKey: "token-1"],
          stdin: Data()
        )
      )
    }
  }

  func testNativeHookCommandIsHiddenAndBuildsBoundedRuntimeInput() throws {
    XCTAssertFalse(AgentsCommand.helpMessage().contains("_hook"))
    let command = try AgentsHookCommand.parse([
      "codex",
      "agent-turn-complete",
      #"{"type":"agent-turn-complete","thread-id":"thread-1","cwd":"/tmp/project","last-assistant-message":"excluded"}"#,
    ])
    let input = try command.makeInput(
      environment: [AgentNativeHookInput.tokenEnvironmentKey: "token-1"],
      stdin: Data()
    )

    XCTAssertEqual(input.runtime, .codex)
    XCTAssertEqual(input.token, "token-1")
    XCTAssertEqual(input.signal.event, .turnEnded)
    XCTAssertEqual(input.signal.sessionID, "thread-1")
    XCTAssertNil(input.signal.detail)
  }

  func testNativeHookCommandRejectsMissingTokenWrongTransportAndOversizedPayload() throws {
    let claude = try AgentsHookCommand.parse(["claude", "Stop"])
    let payload = Data(
      #"{"hook_event_name":"Stop","session_id":"session-1","cwd":"/tmp/project"}"#.utf8
    )
    XCTAssertThrowsError(try claude.makeInput(environment: [:], stdin: payload))

    let codex = try AgentsHookCommand.parse(["codex", "agent-turn-complete"])
    XCTAssertThrowsError(
      try codex.makeInput(
        environment: [AgentNativeHookInput.tokenEnvironmentKey: "token"],
        stdin: payload
      )
    )
    XCTAssertThrowsError(
      try claude.makeInput(
        environment: [AgentNativeHookInput.tokenEnvironmentKey: "token"],
        stdin: Data(repeating: 0, count: AgentNativeHookDecoder.maximumPayloadBytes + 1)
      )
    )
  }

  func testDispatchCompleteParsesRequiredOutcomeAndSummaryFromImplicitContext() throws {
    let command = try AgentsDispatchCompleteCommand.parse([
      "--outcome", "succeeded",
      "--summary", "Implemented and verified.",
      "--json",
    ])
    let input = try command.makeInput(environment: [DispatchCompleteInput.environmentKey: "dispatch-1"])

    XCTAssertEqual(input.dispatchID, "dispatch-1")
    XCTAssertEqual(input.outcome, .succeeded)
    XCTAssertEqual(input.summary, "Implemented and verified.")
    XCTAssertTrue(command.options.json)
  }

  func testDispatchCompleteWithoutLaunchContextSendsNoDispatchID() throws {
    let command = try AgentsDispatchCompleteCommand.parse([
      "--outcome", "failed", "--summary", "SDK unavailable",
    ])
    let input = try command.makeInput(environment: [:])

    XCTAssertNil(input.dispatchID)
    XCTAssertEqual(input.outcome, .failed)
    XCTAssertEqual(input.summary, "SDK unavailable")
  }

  func testDispatchCompleteRejectsInvalidOutcomeAndBoundedSummary() throws {
    XCTAssertThrowsError(
      try AgentsDispatchCompleteCommand.parse(["--outcome", "cancelled", "--summary", "Nope"])
    )
    XCTAssertNoThrow(
      try AgentsDispatchCompleteCommand.parse([
        "--outcome", "failed", "--summary", String(repeating: "x", count: 32_768),
      ])
    )
    XCTAssertThrowsError(
      try AgentsDispatchCompleteCommand.parse([
        "--outcome", "failed", "--summary", String(repeating: "界", count: 10_923),
      ])
    )
  }

  func testDispatchParsesPaneAndReadsMultilinePromptFromPipedStdin() throws {
    let command = try AgentsDispatchCommand.parse(["p7", "--prompt", "-", "--json"])
    let input = try command.makeInput(
      stdinIsTerminal: false,
      readStdin: { Data("Round two.\r\nRe-review the diff.\n\n".utf8) }
    )

    XCTAssertEqual(input.pane, "p7")
    XCTAssertEqual(input.prompt, "Round two.\nRe-review the diff.")
    XCTAssertTrue(command.options.json)
    XCTAssertNil(input.validationErrorMessage)
    XCTAssertEqual(
      try AgentsDispatchCommand.parse(["6E1A2A10-D99F-4E3F-920C-D93AA3C05764", "--prompt", "-"]).pane,
      "6E1A2A10-D99F-4E3F-920C-D93AA3C05764"
    )
  }

  func testDispatchRequiresExplicitPaneStdinPromptAndBoundedControlFreeText() throws {
    XCTAssertThrowsError(try AgentsDispatchCommand.parse(["main", "--prompt", "-"]))
    XCTAssertThrowsError(try AgentsDispatchCommand.parse(["p7"]))
    XCTAssertThrowsError(try AgentsDispatchCommand.parse(["p7", "--prompt", "Inline text"]))

    let command = try AgentsDispatchCommand.parse(["p7", "--prompt", "-"])
    XCTAssertThrowsError(try command.makeInput(stdinIsTerminal: true, readStdin: { Data() })) {
      XCTAssertEqual(($0 as? ExitError)?.code, CLIErrorCode.invalidArgument)
    }
    XCTAssertThrowsError(try command.makeInput(stdinIsTerminal: false, readStdin: { Data("\n\n".utf8) })) {
      XCTAssertEqual(($0 as? ExitError)?.code, CLIErrorCode.emptyInput)
    }
    XCTAssertThrowsError(try command.makeInput(stdinIsTerminal: false, readStdin: { Data("bell\u{07}".utf8) })) {
      XCTAssertEqual(($0 as? ExitError)?.code, CLIErrorCode.invalidArgument)
    }
    XCTAssertThrowsError(
      try command.makeInput(
        stdinIsTerminal: false,
        readStdin: { Data(repeating: UInt8(ascii: "x"), count: DispatchInput.maximumPromptUTF8ByteCount + 1) }
      )
    ) {
      XCTAssertEqual(($0 as? ExitError)?.code, CLIErrorCode.invalidArgument)
    }
  }

  func testDispatchAbandonParsesIDAndReasonAndRejectsBoundViolations() throws {
    let command = try AgentsDispatchAbandonCommand.parse([
      "--dispatch", "dispatch-1", "--reason", "Worker returned to a shell.", "--json",
    ])

    XCTAssertEqual(command.dispatchID, "dispatch-1")
    XCTAssertEqual(command.reason, "Worker returned to a shell.")
    XCTAssertThrowsError(
      try AgentsDispatchAbandonCommand.parse([
        "--dispatch", "dispatch-1", "--reason", String(repeating: "\n", count: 1),
      ])
    )
  }

  func testWaitParsesDispatchModeWithExactScreenLineCount() throws {
    let command = try AgentsWaitCommand.parse([
      "--dispatch", "dispatch-1", "--timeout", "45", "--include-screen", "80", "--json",
    ])
    let input = try command.makeInput()

    XCTAssertEqual(input.mode, .dispatch)
    XCTAssertEqual(input.dispatchID, "dispatch-1")
    XCTAssertNil(input.pane)
    XCTAssertNil(input.condition)
    XCTAssertEqual(input.timeoutSeconds, 45)
    XCTAssertEqual(input.includeScreenLines, 80)
  }

  func testWaitParsesConditionModeAndExplicitAutoConfidence() throws {
    let command = try AgentsWaitCommand.parse([
      "p7", "--until", "changed", "--min-confidence", "auto",
    ])
    let input = try command.makeInput()

    XCTAssertEqual(input.mode, .condition)
    XCTAssertEqual(input.pane, "p7")
    XCTAssertEqual(input.condition, .changed)
    XCTAssertEqual(input.minimumConfidence, .auto)
    XCTAssertEqual(input.timeoutSeconds, 600)
  }

  func testWaitRejectsModeConflictsMissingConditionAndBounds() throws {
    XCTAssertThrowsError(try AgentsWaitCommand.parse(["p7", "--until", "idle", "--dispatch", "dispatch-1"]))
    XCTAssertThrowsError(try AgentsWaitCommand.parse(["--dispatch", "dispatch-1", "--until", "idle"]))
    XCTAssertThrowsError(try AgentsWaitCommand.parse(["p7"]))
    XCTAssertThrowsError(try AgentsWaitCommand.parse(["p7", "--until", "idle", "--timeout", "0"]))
    XCTAssertThrowsError(try AgentsWaitCommand.parse(["p7", "--until", "idle", "--timeout", "601"]))
    XCTAssertThrowsError(try AgentsWaitCommand.parse(["p7", "--until", "idle", "--include-screen", "0"]))
    XCTAssertThrowsError(try AgentsWaitCommand.parse(["p7", "--until", "idle", "--include-screen", "201"]))
    XCTAssertThrowsError(try AgentsWaitCommand.parse(["--dispatch", "dispatch-1", "--min-confidence", "exact"]))
  }
}
