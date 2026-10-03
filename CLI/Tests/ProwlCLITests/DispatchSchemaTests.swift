import Foundation
import JSONSchema
import ProwlCLIContracts
import XCTest

final class DispatchSchemaTests: XCTestCase {
  func testSchemaPublishesGovernedDispatchDefinitionsAndErrorDetails() throws {
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: ProwlCLIContractBundle.schemaData) as? [String: Any]
    )
    let definitions = try XCTUnwrap(root["$defs"] as? [String: Any])
    for name in [
      "dispatchPendingRecord",
      "dispatchCompletedRecord",
      "dispatchGoneRecord",
      "dispatchAbandonedRecord",
      "dispatchRecord",
      "agentSignals",
      "agentWaitScreen",
      "agentsDispatchResponse",
      "agentsDispatchErrorDetails",
      "agentsDispatchCompleteResponse",
      "agentsDispatchAbandonResponse",
      "agentsWaitResponse",
    ] {
      XCTAssertNotNil(definitions[name], "Missing schema definition: \(name)")
    }

    let error = try XCTUnwrap(definitions["error"] as? [String: Any])
    let properties = try XCTUnwrap(error["properties"] as? [String: Any])
    XCTAssertNotNil(properties["details"])
    XCTAssertEqual(Set(try XCTUnwrap(error["required"] as? [String])), ["code", "message"])
  }

  func testSchemaAcceptsStrictDispatchSuccessAndWaitFailureFixtures() throws {
    let completion = #"{"ok":true,"command":"agents.dispatch-complete","schema_version":"prowl.cli.agents.dispatch-complete.v1","data":{"target":{"worktree":{"id":"wt","name":"main","path":"/Projects/Prowl","root_path":"/Projects/Prowl","kind":"git"},"tab":{"id":"tab","title":"Tab","selected":true},"pane":{"id":"pane","title":"Pane","cwd":"/Projects/Prowl","focused":true}},"receipt":{"id":"d1","state":"completed","outcome":"succeeded","summary":"Done","created_at":"2026-08-23T02:00:00.000Z","completed_at":"2026-08-23T02:01:00.000Z"},"replayed":false}}"#
    let timeout = #"{"ok":false,"command":"agents.wait","schema_version":"prowl.cli.agents.wait.v1","error":{"code":"WAIT_TIMEOUT","message":"Timed out.","details":{"mode":"dispatch","waited_ms":600000,"target":{"worktree":{"id":"wt","name":"main","path":"/Projects/Prowl","root_path":"/Projects/Prowl","kind":"git"},"tab":{"id":"tab","title":"Tab","selected":true},"pane":{"id":"pane","title":"Pane","cwd":"/Projects/Prowl","focused":true}},"record":{"id":"d1","state":"pending","created_at":"2026-08-23T02:00:00.000Z"},"screen":{"status":"unavailable","requested_lines":20,"source":"detection","waited_ms":0}}}}"#

    try assertValid(completion)
    try assertValid(timeout)
  }

  func testSchemaAcceptsDispatchSuccessAndStructuredRefusalsButNotUnknownDetails() throws {
    let target =
      #"{"worktree":{"id":"wt","name":"main","path":"/Projects/Prowl","root_path":"/Projects/Prowl","kind":"git"},"tab":{"id":"tab","title":"Tab","selected":true},"pane":{"id":"pane","title":"Pane","cwd":"/Projects/Prowl","focused":true}}"#
    let success =
      #"{"ok":true,"command":"agents.dispatch","schema_version":"prowl.cli.agents.dispatch.v1","data":{"target":"# + target
      + #","dispatch":{"id":"d2","state":"pending","created_at":"2026-08-29T02:00:00.000Z"}}}"#
    let pending =
      #"{"ok":false,"command":"agents.dispatch","schema_version":"prowl.cli.agents.dispatch.v1","error":{"code":"DISPATCH_PENDING","message":"Pending.","details":{"target":"# + target
      + #","record":{"id":"d1","state":"pending","created_at":"2026-08-29T02:00:00.000Z"}}}}"#
    let busy =
      #"{"ok":false,"command":"agents.dispatch","schema_version":"prowl.cli.agents.dispatch.v1","error":{"code":"DISPATCH_TARGET_BUSY","message":"Busy.","details":{"target":"# + target
      + #","observation":{"status":"working","raw_state":"working","source":"detection","confidence":"heuristic","at":"2026-08-29T02:00:00.000Z","revision":3},"signals":{"channels":[]}}}}"#
    let unknown =
      #"{"ok":false,"command":"agents.dispatch","schema_version":"prowl.cli.agents.dispatch.v1","error":{"code":"DISPATCH_PENDING","message":"Pending.","details":{"target":"# + target
      + #","waited_ms":1}}}"#
    let extraData =
      #"{"ok":true,"command":"agents.dispatch","schema_version":"prowl.cli.agents.dispatch.v1","data":{"target":"# + target
      + #","dispatch":{"id":"d2","state":"pending","created_at":"2026-08-29T02:00:00.000Z"},"delivered":true}}"#

    try assertValid(success)
    try assertValid(pending)
    try assertValid(busy)
    try assertInvalid(unknown)
    try assertInvalid(extraData)
  }

  func testSchemaRejectsCrossVariantFieldsAndUnknownWaitDetails() throws {
    let invalidRecord = #"{"ok":true,"command":"agents.dispatch-complete","schema_version":"prowl.cli.agents.dispatch-complete.v1","data":{"target":{"worktree":{"id":"wt","name":"main","path":"/Projects/Prowl","root_path":"/Projects/Prowl","kind":"git"},"tab":{"id":"tab","title":"Tab","selected":true},"pane":{"id":"pane","title":"Pane","cwd":"/Projects/Prowl","focused":true}},"receipt":{"id":"d1","state":"completed","outcome":"succeeded","summary":"Done","created_at":"now","completed_at":"later","gone_at":"illegal"},"replayed":false}}"#
    let invalidDetails = #"{"ok":false,"command":"agents.wait","schema_version":"prowl.cli.agents.wait.v1","error":{"code":"WAIT_TIMEOUT","message":"Timed out.","details":{"mode":"dispatch","waited_ms":1,"unexpected":true}}}"#

    try assertInvalid(invalidRecord)
    try assertInvalid(invalidDetails)
  }

  private func assertValid(_ instance: String) throws {
    let schemaText = try XCTUnwrap(String(data: ProwlCLIContractBundle.schemaData, encoding: .utf8))
    let result = try Schema(instance: schemaText).validate(instance: instance)
    XCTAssertTrue(result.isValid, "Expected valid schema fixture: \(result.errors ?? [])")
  }

  private func assertInvalid(_ instance: String) throws {
    let schemaText = try XCTUnwrap(String(data: ProwlCLIContractBundle.schemaData, encoding: .utf8))
    let result = try Schema(instance: schemaText).validate(instance: instance)
    XCTAssertFalse(result.isValid)
  }
}
