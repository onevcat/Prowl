import Foundation
import JSONSchema
import ProwlCLIContracts
import ProwlCLIShared
import XCTest
import Yams

final class WorkflowSchemaTests: XCTestCase {
  // MARK: - CLI output contract (prowl.cli.workflow.v1)

  func testOutputSchemaAcceptsEveryAction() throws {
    let entry =
      #"{"id":"demo","name":"Demo","description":"d","scope":"user","path":"/Users/me/.prowl/workflows/demo.yaml","enabled":true,"valid":true,"errors":0,"warnings":1,"shadowed":false}"#
    let unparsed =
      #"{"scope":"repo","path":"/Projects/App/.prowl/workflows/broken.yaml","enabled":false,"valid":false,"errors":1,"warnings":0,"shadowed":false}"#
    let list =
      #"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v1","data":{"action":"list","worktree":{"id":"w","name":"main","path":"/Projects/App","root_path":"/Projects/App"},"sources":{"bundle":"/Applications/Prowl.app/Contents/Resources/workflows","user":"/Users/me/.prowl/workflows","repo":"/Projects/App/.prowl/workflows"},"workflows":[\#(entry),\#(unparsed)]}}"#
    let listWithoutWorktree =
      #"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v1","data":{"action":"list","sources":{"user":"/Users/me/.prowl/workflows"},"workflows":[]}}"#
    let validate =
      #"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v1","data":{"action":"validate","path":"/x.yaml","valid":true,"workflow":{"id":"demo","name":"Demo"},"diagnostics":[{"severity":"warning","code":"timeout_long","message":"long","line":4,"column":7},{"severity":"warning","code":"skill_unchecked","message":"unchecked"}]}}"#
    let schema =
      #"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v1","data":{"action":"schema","schema":{"$id":"x","type":"object"}}}"#
    let error =
      #"{"ok":false,"command":"workflow","schema_version":"prowl.cli.workflow.v1","error":{"code":"WORKFLOW_INVALID","message":"2 error(s).","details":{"action":"validate","path":"/x.yaml","valid":false,"diagnostics":[]}}}"#
    let run =
      ###"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v1","data":{"action":"run",\###(Self.runFields)}}"###
    let status =
      ###"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v1","data":{"action":"status",\###(Self.recordFields)}}"###
    let cancel =
      ###"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v1","data":{"action":"cancel",\###(Self.runFields)}}"###
    let done =
      ###"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v1","data":{"action":"deliver","run":{\###(Self.runFields)},"delivery":{"state":"provisional","ordinal":1,"step":"brief","role":"author","output":\###(Self.output),"warnings":[{"code":"missing_sections","message":"missing ## Claims"}]}}}"###
    let read =
      #"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v1","data":{"action":"read","run":"0BADCAFE-0000-4000-8000-000000000042","invocation":1,"role":"author","step":"brief","resource":"instruction","body":"Read","encoding":"utf-8","resources":[],"offset":0,"next_offset":4,"total_bytes":8}}"#
    for instance in [list, listWithoutWorktree, validate, schema, error, run, status, cancel, done, read] {
      try assertValidity(instance, expected: true)
    }
  }

  func testOutputSchemaRejectsMalformedRuntimePayloads() throws {
    let badDeliveryState =
      ###"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v1","data":{"action":"deliver","run":{\###(Self.runFields)},"delivery":{"state":"accepted","ordinal":1,"step":"brief","role":"author","output":\###(Self.output),"warnings":[]}}}"###
    let badBindingSource =
      ###"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v1","data":{"action":"run",\###(Self.runFields.replacingOccurrences(of: #""source":"current""#, with: #""source":"remote""#))}}"###
    let badState =
      ###"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v1","data":{"action":"status",\###(Self.recordFields.replacingOccurrences(of: #""state":"interrupted""#, with: #""state":"paused""#))}}"###
    let missingRunDirectory =
      ###"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v1","data":{"action":"cancel",\###(Self.runFields.replacingOccurrences(of: #""run_directory":"/Projects/App/.prowl/workflow-runs/0BADCAFE-0000-4000-8000-000000000042","#, with: ""))}}"###
    for instance in [badDeliveryState, badBindingSource, badState, missingRunDirectory] {
      try assertValidity(instance, expected: false)
    }
  }

  func testReadSchemaRejectsInvalidEncodingAndMissingInvocation() throws {
    let payload = WorkflowCommandPayload.read(WorkflowContentPayload(
      run: UUID().uuidString, invocation: 1, role: "author", step: "brief", resource: "resource-1",
      body: "AA==", encoding: "base64", resources: [], offset: 4, totalBytes: 5))
    let response = try CommandResponse(
      ok: true, command: "workflow", schemaVersion: "prowl.cli.workflow.v1", data: RawJSON(encoding: payload))
    let data = try JSONEncoder().encode(response)
    let json = String(decoding: data, as: UTF8.self)
    try assertValidity(json, expected: true)
    try assertValidity(json.replacing("base64", with: "hex"), expected: false)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var fields = try XCTUnwrap(object["data"] as? [String: Any])
    fields.removeValue(forKey: "invocation")
    object["data"] = fields
    let missingInvocation = try JSONSerialization.data(withJSONObject: object)
    try assertValidity(String(decoding: missingInvocation, as: UTF8.self), expected: false)
  }

  func testRuntimePayloadsRoundTripThroughCodable() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let output = WorkflowDeliveryRecordPayload(
      name: "brief", ordinal: 1, path: "/r/deliveries/brief.1.md", latestPath: "/r/deliveries/brief.md", verdict: nil,
      deliveredAt: "2026-08-30T01:02:03Z")
    let run = WorkflowRunPayload(
      id: "0BADCAFE-0000-4000-8000-000000000042",
      workflow: WorkflowIdentity(id: "prowl.adversarial-review", name: "Adversarial Review"),
      scope: .repo,
      definitionPath: "/Projects/App/.prowl/workflows/review.yaml",
      source: .live,
      status: WorkflowRunStatusPayload(
        state: "needs_attention", step: "brief",
        attention: WorkflowAttentionPayload(
          reason: "delivery_issues", message: "m", step: "brief", role: "author", ordinal: 1,
          actions: ["accept_delivery", "ask_again", "skip", "cancel"], issues: ["missing_sections"])),
      step: "brief",
      role: "author",
      worktree: WorkflowRunWorktreePayload(id: "wt", name: "feature", branch: "feat/x", path: "/Projects/App"),
      runDirectory: "/r",
      bindings: [
        "author": WorkflowBindingPayload(
          source: .current,
          pane: WorkflowPaneBindingPayload(
            id: "00000000-0000-0000-0000-000000000001", tabID: nil, handle: "p1", displayName: "Claude Code",
            agent: "claude")),
        "reviewer": WorkflowBindingPayload(
          source: .launch,
          profile: WorkflowProfileBindingPayload(id: "00000000-0000-0000-0000-000000000009", name: "Pi", agent: "pi")),
      ],
      activation: WorkflowActivationPayload(
        ordinal: 1, step: "brief", role: "author", state: "provisional", dispatchID: "dispatch-1", output: "brief",
        expect: WorkflowExpectationPayload(
          format: .markdown, sections: ["## Scope"], verdicts: nil, strict: false,
          completion: ["PROWL_WORKFLOW_TOKEN=T prowl workflow deliver -"]),
        deadline: nil),
      deliveries: ["brief": output],
      startedAt: "2026-08-30T01:00:00Z",
      updatedAt: "2026-08-30T01:02:03Z",
      finishedAt: nil,
      selfInitiated: WorkflowSelfInitiatedPayload(
        line: "[Prowl] Read /r/instructions/brief.1.md and follow it — finish with: PROWL_WORKFLOW_TOKEN=T prowl workflow deliver -",
        instructionPath: "/r/instructions/brief.1.md",
        completion: ["PROWL_WORKFLOW_TOKEN=T prowl workflow deliver -"]))
    let done = WorkflowCommandPayload.deliver(
      WorkflowDeliverPayload(
        run: run,
        delivery: WorkflowDeliveryPayload(
          state: .provisional, ordinal: 1, step: "brief", role: "author", output: output,
          warnings: [WorkflowDeliveryWarningPayload(code: "missing_sections", message: "missing ## Claims")])))
    for payload in [WorkflowCommandPayload.run(run), .status(run), .cancel(run), done] {
      let data = try encoder.encode(payload)
      XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix(#"{"action":"\#(payload.action.rawValue)""#))
      XCTAssertEqual(try JSONDecoder().decode(WorkflowCommandPayload.self, from: data), payload)
      try assertValidity(
        #"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v1","data":\#(String(decoding: data, as: UTF8.self))}"#,
        expected: true)
    }
  }

  private static let output =
    #"{"name":"brief","ordinal":1,"path":"/r/deliveries/brief.1.md","latest_path":"/r/deliveries/brief.md","delivered_at":"2026-08-30T01:02:03Z"}"#

  private static let runFields =
    ###""id":"0BADCAFE-0000-4000-8000-000000000042","workflow":{"id":"prowl.adversarial-review","name":"Adversarial Review"},"scope":"repo","definition_path":"/Projects/App/.prowl/workflows/review.yaml","source":"live","status":{"state":"running"},"step":"brief","role":"author","worktree":{"id":"wt","name":"feature","branch":"feat/x","path":"/Projects/App"},"run_directory":"/Projects/App/.prowl/workflow-runs/0BADCAFE-0000-4000-8000-000000000042","bindings":{"author":{"source":"current","pane":{"id":"00000000-0000-0000-0000-000000000001","tab_id":"00000000-0000-0000-0000-000000000011","handle":"p1","display_name":"Claude Code","agent":"claude"}},"reviewer":{"source":"launch","profile":{"id":"00000000-0000-0000-0000-000000000009","name":"Pi Reviewer","agent":"pi"}}},"activation":{"ordinal":1,"step":"brief","role":"author","state":"waiting","dispatch_id":"dispatch-1","output":"brief","expect":{"format":"markdown","sections":["## Scope","## Claims"],"strict":false,"completion":["PROWL_WORKFLOW_TOKEN=T prowl workflow deliver -"]},"deadline":"2026-08-30T01:10:00Z"},"deliveries":{},"started_at":"2026-08-30T01:00:00Z","updated_at":"2026-08-30T01:00:00Z","self_initiated":{"line":"[Prowl] Read /r/instructions/brief.1.md and follow it — finish with: PROWL_WORKFLOW_TOKEN=T prowl workflow deliver -","instruction_path":"/r/instructions/brief.1.md","completion":["PROWL_WORKFLOW_TOKEN=T prowl workflow deliver -"]}"###

  private static let recordFields =
    ###""id":"0BADCAFE-0000-4000-8000-000000000042","workflow":{"id":"prowl.handoff","name":"Hand Off"},"scope":"bundle","source":"record","status":{"state":"interrupted"},"worktree":{"id":"wt","name":"feature","branch":"feat/x","path":"/Projects/App"},"run_directory":"/Projects/App/.prowl/workflow-runs/0BADCAFE-0000-4000-8000-000000000042","bindings":{"source":{"source":"current","pane":{"id":"00000000-0000-0000-0000-000000000001","handle":"p1","display_name":"shell"}}},"deliveries":{"brief":\###(WorkflowSchemaTests.output)},"started_at":"2026-08-30T01:00:00Z","updated_at":"2026-08-30T01:05:00Z","finished_at":"2026-08-30T01:05:00Z""###

  func testOutputSchemaRejectsUnknownFieldsBadScopesAndCrossActionFields() throws {
    let unknownField =
      #"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v1","data":{"action":"list","sources":{"user":"/u"},"workflows":[],"extra":1}}"#
    let badScope =
      #"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v1","data":{"action":"list","sources":{"user":"/u"},"workflows":[{"scope":"global","path":"/p","enabled":true,"valid":true,"errors":0,"warnings":0,"shadowed":false}]}}"#
    let crossAction =
      #"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v1","data":{"action":"schema","schema":{},"workflows":[]}}"#
    let badSeverity =
      #"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v1","data":{"action":"validate","path":"/x","valid":false,"diagnostics":[{"severity":"fatal","code":"c","message":"m"}]}}"#
    let wrongVersion =
      #"{"ok":true,"command":"workflow","schema_version":"prowl.cli.workflow.v2","data":{"action":"schema","schema":{}}}"#
    for instance in [unknownField, badScope, crossAction, badSeverity, wrongVersion] {
      try assertValidity(instance, expected: false)
    }
  }

  func testPayloadRoundTripsThroughCodableWithTheActionDiscriminator() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let validate = WorkflowCommandPayload.validate(
      WorkflowValidatePayload(
        path: "/x.yaml", valid: false, workflow: WorkflowIdentity(id: "demo", name: "Demo"),
        diagnostics: [
          WorkflowDiagnosticPayload(severity: .error, code: "undefined_role", message: "Role 'x'", line: 3, column: 5)
        ]))
    let data = try encoder.encode(validate)
    XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix(#"{"action":"validate""#))
    XCTAssertEqual(try JSONDecoder().decode(WorkflowCommandPayload.self, from: data), validate)

    let list = WorkflowCommandPayload.list(
      WorkflowListPayload(worktree: nil, sources: WorkflowListSources(bundle: nil, user: "/u", repo: nil), workflows: []))
    XCTAssertEqual(
      String(decoding: try encoder.encode(list), as: UTF8.self),
      #"{"action":"list","sources":{"user":"/u"},"workflows":[]}"#)
    let schema = WorkflowCommandPayload.schema(WorkflowSchemaPayload(schema: RawJSON(Data(#"{"type":"object"}"#.utf8))))
    XCTAssertEqual(try JSONDecoder().decode(WorkflowCommandPayload.self, from: try encoder.encode(schema)), schema)
  }

  // MARK: - Workflow definition schema

  func testDefinitionSchemaResourceMatchesTheSwiftConstant() throws {
    let resource = try JSONSerialization.jsonObject(with: ProwlCLIContractBundle.workflowDefinitionSchemaData)
    let constant = try WorkflowJSONSchema.definitionSchemaObject()
    XCTAssertEqual(resource as? NSDictionary, constant as NSDictionary)
    XCTAssertEqual(constant["$id"] as? String, WorkflowJSONSchema.identifier)
  }

  func testDefinitionSchemaAcceptsTheSpecExampleAndRejectsStructuralErrors() throws {
    try assertDefinitionValidity(WorkflowFixtures.adversarialReview, expected: true)
    try assertDefinitionValidity(WorkflowFixtures.minimal(), expected: true)

    let unknownKey = WorkflowFixtures.minimal() + "bogus: 1\n"
    let twoVerbs = WorkflowFixtures.minimal(extraSteps: "  - id: b\n    notify: x\n    close: author")
    let headless = WorkflowFixtures.minimal(extraRoles: "  r:\n    source: launch\n    kind: headless")
    let badMax = WorkflowFixtures.minimal(
      extraSteps: "  - id: loop\n    repeat: { max: 21 }\n    steps:\n      - id: x\n        notify: hi")
    let launchInLoop = WorkflowFixtures.minimal(
      extraSteps: "  - id: loop\n    repeat: { max: 2 }\n    steps:\n      - id: l\n        launch: r\n        prompt: go",
      extraRoles: "  r:\n    source: launch")
    let orphanPolicy = WorkflowFixtures.minimal(
      extraSteps: "  - id: b\n    message: author\n    text: hi\n    expect: { on_timeout: skip }")
    for (name, yaml) in [
      ("unknownKey", unknownKey), ("twoVerbs", twoVerbs), ("headless", headless), ("badMax", badMax),
      ("launchInLoop", launchInLoop), ("orphanPolicy", orphanPolicy),
    ] {
      try assertDefinitionValidity(yaml, expected: false, name)
    }
  }

  // MARK: - Helpers

  private func assertValidity(_ instance: String, expected: Bool) throws {
    let schemaText = try XCTUnwrap(String(data: ProwlCLIContractBundle.schemaData, encoding: .utf8))
    let result = try Schema(instance: schemaText).validate(instance: instance)
    XCTAssertEqual(result.isValid, expected, "Schema errors for \(instance): \(result.errors ?? [])")
  }

  private func assertDefinitionValidity(_ yaml: String, expected: Bool, _ name: String = "") throws {
    let object = try XCTUnwrap(Yams.load(yaml: yaml))
    let json = try JSONSerialization.data(withJSONObject: object)
    let result = try Schema(instance: WorkflowJSONSchema.definitionSchemaJSON)
      .validate(instance: String(decoding: json, as: UTF8.self))
    XCTAssertEqual(result.isValid, expected, "\(name): \(result.errors ?? [])")
  }
}
