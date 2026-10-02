import Foundation
import ProwlCLIShared
import XCTest

final class DispatchWireModelTests: XCTestCase {
  func testInteractiveInputRoundTripsWithoutDispatchMetadata() throws {
    let input = DispatchInput(pane: UUID().uuidString, prompt: "你好\nfollow-up")
    let data = try JSONEncoder().encode(CommandEnvelope(output: .json, command: .agentsInput(input)))
    let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: data)
    XCTAssertEqual(decoded.command.name, "agents.input")
    guard case .agentsInput(let actual) = decoded.command else {
      return XCTFail("Expected interactive input")
    }
    XCTAssertEqual(actual, input)
  }

  func testDispatchCommandsRoundTripWithStableNames() throws {
    let commands: [Command] = [
      .agentsDispatch(DispatchInput(pane: "p7", prompt: "Round two.\nRe-review the diff.")),
      .agentsDispatchComplete(
        DispatchCompleteInput(dispatchID: "dispatch-1", outcome: .succeeded, summary: "Done")
      ),
      .agentsDispatchAbandon(
        DispatchAbandonInput(dispatchID: "dispatch-2", reason: "Worker stopped reporting")
      ),
      .agentsWait(
        AgentWaitInput(mode: .dispatch, dispatchID: "dispatch-3")
      ),
    ]

    XCTAssertEqual(
      commands.map(\.name),
      ["agents.dispatch", "agents.dispatch-complete", "agents.dispatch-abandon", "agents.wait"]
    )
    for command in commands {
      let data = try JSONEncoder().encode(CommandEnvelope(output: .json, command: command))
      let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: data)
      XCTAssertEqual(decoded.command.name, command.name)
    }
  }

  func testDispatchCompleteInputCarriesTheLaunchIDOnlyAsOptionalDiagnostics() throws {
    let withoutID = try JSONEncoder().encode(
      CommandEnvelope(
        output: .json,
        command: .agentsDispatchComplete(DispatchCompleteInput(dispatchID: nil, outcome: .succeeded, summary: "Done"))
      ))
    guard case .agentsDispatchComplete(let decoded) = try JSONDecoder().decode(CommandEnvelope.self, from: withoutID).command
    else {
      return XCTFail("Expected agents.dispatch-complete")
    }
    XCTAssertNil(decoded.dispatchID)
    XCTAssertNil(decoded.validationErrorMessage)

    let legacy = Data(
      #"{"output":"json","command":{"agentsDispatchComplete":{"_0":{"dispatch_id":"d1","outcome":"failed","summary":"No"}}}}"#
        .utf8)
    guard case .agentsDispatchComplete(let legacyInput) = try JSONDecoder().decode(CommandEnvelope.self, from: legacy).command
    else {
      return XCTFail("Expected agents.dispatch-complete")
    }
    XCTAssertEqual(legacyInput.dispatchID, "d1")
  }

  func testCommandErrorDetailsRoundTripWithoutChangingLegacyErrors() throws {
    let details = try RawJSON(
      encoding: ["mode": "dispatch", "waited_ms": "120"]
    )
    let modern = CommandError(code: "WAIT_TIMEOUT", message: "Timed out.", details: details)
    let modernData = try JSONEncoder().encode(modern)
    let modernJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: modernData) as? [String: Any]
    )
    XCTAssertNotNil(modernJSON["details"])
    XCTAssertNotNil(try JSONDecoder().decode(CommandError.self, from: modernData).details)

    let legacyData = try JSONEncoder().encode(CommandError(code: "INVALID_ARGUMENT", message: "Bad input."))
    let legacyJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
    )
    XCTAssertNil(legacyJSON["details"])
  }

  func testDispatchRecordTaggedUnionEncodesOnlyVariantFields() throws {
    let records: [(DispatchRecordPayload, String, Set<String>)] = [
      (
        .pending(DispatchPendingRecord(id: "d1", createdAt: "2026-08-23T02:00:00.000Z")),
        "pending",
        ["id", "state", "created_at"]
      ),
      (
        .completed(
          DispatchCompletedRecord(
            id: "d2",
            outcome: .succeeded,
            summary: "Done",
            createdAt: "2026-08-23T02:00:00.000Z",
            completedAt: "2026-08-23T02:01:00.000Z"
          )
        ),
        "completed",
        ["id", "state", "outcome", "summary", "created_at", "completed_at"]
      ),
      (
        .gone(
          DispatchGoneRecord(
            id: "d3",
            createdAt: "2026-08-23T02:00:00.000Z",
            goneAt: "2026-08-23T02:01:00.000Z",
            reason: .surfaceClosed
          )
        ),
        "gone",
        ["id", "state", "created_at", "gone_at", "gone_reason"]
      ),
      (
        .abandoned(
          DispatchAbandonedRecord(
            id: "d4",
            createdAt: "2026-08-23T02:00:00.000Z",
            abandonedAt: "2026-08-23T02:01:00.000Z",
            reason: "Worker returned to shell"
          )
        ),
        "abandoned",
        ["id", "state", "created_at", "abandoned_at", "reason"]
      ),
    ]

    for (record, state, keys) in records {
      let data = try JSONEncoder().encode(record)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(object["state"] as? String, state)
      XCTAssertEqual(Set(object.keys), keys)
      XCTAssertEqual(try JSONDecoder().decode(DispatchRecordPayload.self, from: data), record)
    }
  }

  func testDispatchRecordRejectsCrossVariantAndUnknownFields() {
    let crossVariant = Data(
      #"{"id":"d1","state":"pending","created_at":"now","summary":"illegal"}"#.utf8
    )
    let unknown = Data(
      #"{"id":"d1","state":"gone","created_at":"now","gone_at":"later","gone_reason":"surface_closed","extra":true}"#.utf8
    )

    XCTAssertThrowsError(try JSONDecoder().decode(DispatchRecordPayload.self, from: crossVariant))
    XCTAssertThrowsError(try JSONDecoder().decode(DispatchRecordPayload.self, from: unknown))
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        DispatchCompletedRecord.self,
        from: Data(
          #"{"id":"d1","state":"pending","outcome":"succeeded","summary":"Done","created_at":"now","completed_at":"later"}"#.utf8
        )
      )
    )
  }

  func testWaitPayloadAndErrorDetailsRoundTripAsStrictTaggedUnions() throws {
    let observation = AgentWaitObservation(
      status: .blocked,
      rawState: "blocked",
      source: "cooperative_cli",
      confidence: "exact",
      timestamp: "2026-08-23T02:01:00.000Z",
      revision: 42
    )
    let condition = AgentWaitCommandPayload.condition(
      AgentConditionWaitPayload(
        condition: .blocked,
        waitedMilliseconds: 123,
        target: Self.target,
        observation: observation,
        signals: AgentSignalsPayload(channels: [], last: nil, lastBinding: nil),
        screen: .captured(
          AgentWaitCapturedScreen(
            requestedLines: 20,
            waitedMilliseconds: 800,
            text: "Need input",
            lineCount: 1,
            stabilized: true
          )
        )
      )
    )
    XCTAssertEqual(
      try JSONDecoder().decode(AgentWaitCommandPayload.self, from: JSONEncoder().encode(condition)),
      condition
    )

    let details = AgentWaitErrorDetails.condition(
      AgentConditionWaitErrorDetails(
        condition: .changed,
        waitedMilliseconds: 600_000,
        target: Self.target,
        observation: observation,
        signals: nil,
        screen: .unavailable(
          AgentWaitUnavailableScreen(requestedLines: 20, waitedMilliseconds: 0)
        )
      )
    )
    XCTAssertEqual(
      try JSONDecoder().decode(AgentWaitErrorDetails.self, from: JSONEncoder().encode(details)),
      details
    )

    let illegal = Data(
      #"{"mode":"dispatch","waited_ms":1,"target":{},"receipt":{},"condition":"idle"}"#.utf8
    )
    XCTAssertThrowsError(try JSONDecoder().decode(AgentWaitCommandPayload.self, from: illegal))

    let wrongScreenSource = Data(
      #"{"status":"captured","requested_lines":1,"source":"viewport","waited_ms":800,"text":"Done","line_count":1,"stabilized":true}"#.utf8
    )
    XCTAssertThrowsError(try JSONDecoder().decode(AgentWaitScreenPayload.self, from: wrongScreenSource))
  }

  func testCreateDispatchAndAgentSignalsRemainOptionalAdditiveFields() throws {
    let dispatch = DispatchPendingRecord(id: "d1", createdAt: "2026-08-23T02:00:00.000Z")
    let lifecycle = LifecycleCommandPayload(
      resource: .tab,
      dispatch: dispatch,
      target: Self.target
    )
    let lifecycleData = try JSONEncoder().encode(lifecycle)
    let lifecycleJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: lifecycleData) as? [String: Any]
    )
    XCTAssertNotNil(lifecycleJSON["dispatch"])

    let signals = AgentSignalsPayload(channels: [], last: nil, lastBinding: nil)
    let agent = AgentsCommandAgent(
      id: "pane-1",
      type: "codex",
      name: "codex",
      status: .idle,
      rawState: "idle",
      lastChangedAt: "2026-08-23T02:00:00Z",
      project: AgentsCommandProject(name: "Prowl", branch: "main", path: "/Projects/Prowl"),
      worktree: AgentsCommandWorktree(
        id: "wt", name: "main", path: "/Projects/Prowl", rootPath: "/Projects/Prowl", kind: "git"
      ),
      tab: AgentsCommandTab(id: "tab", title: "Tab", selected: true),
      pane: AgentsCommandPane(id: "pane-1", index: 0, title: "Pane", cwd: "/Projects/Prowl", focused: true),
      signals: signals
    )
    XCTAssertEqual(try JSONDecoder().decode(AgentsCommandAgent.self, from: JSONEncoder().encode(agent)).signals, signals)
  }

  private static let target = TabTarget(
    worktree: TabTargetWorktree(
      id: "wt", name: "main", path: "/Projects/Prowl", rootPath: "/Projects/Prowl", kind: "git"
    ),
    tab: TabTargetTab(id: "tab", title: "Tab", selected: true),
    pane: TabTargetPane(id: "pane", title: "Pane", cwd: "/Projects/Prowl", focused: true)
  )
}
