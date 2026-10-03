import Foundation
import JSONSchema
import ProwlCLIContracts
import ProwlCLIShared
import XCTest

final class LifecycleWarningSchemaTests: XCTestCase {
  func testCreateSchemaAcceptsManagedHookWarningAndRejectsUnknownFields() throws {
    let valid = #"{"ok":true,"command":"create","schema_version":"prowl.cli.create.v1","data":{"resource":"tab","launch":{"profile_id":"D2719F02-5F27-4D46-A62F-0FAF49410D4D","profile_name":"Codex","agent":"codex"},"warnings":[{"code":"managed_hook_degraded","runtime":"codex","message":"Notifier resolver unavailable."}],"target":{"worktree":{"id":"wt","name":"main","path":"/Projects/Prowl","root_path":"/Projects/Prowl","kind":"git"},"tab":{"id":"tab","title":"Tab","selected":true},"pane":{"id":"pane","title":"Pane","cwd":"/Projects/Prowl","focused":true}}}}"#
    let invalid = valid.replacingOccurrences(of: #""message":"Notifier resolver unavailable.""#, with: #""message":"Notifier resolver unavailable.","secret":"leak""#)

    try assertValidity(valid, expected: true)
    try assertValidity(invalid, expected: false)
  }

  func testAgentSignalSchemaAcceptsManagedHookSourcesWithoutTokenField() throws {
    let response = #"{"ok":true,"command":"agents.signal","schema_version":"prowl.cli.agents.signal.v1","data":{"pane":{"id":"D2719F02-5F27-4D46-A62F-0FAF49410D4D","worktree_id":"wt"},"signal":{"event":"turn-ended","source":"hook_codex","confidence":"exact","binding":"current","at":"2026-08-24T00:00:00.000Z","session_id":"thread-1"}}}"#
    try assertValidity(response, expected: true)
    XCTAssertFalse(response.contains("token"))
  }

  func testLifecyclePayloadOmitsEmptyWarningsAndDecodesAdditiveWarnings() throws {
    let target = TabTarget(
      worktree: .init(id: "wt", name: "main", path: "/tmp", rootPath: "/tmp", kind: "git"),
      tab: .init(id: "tab", title: "Tab", selected: true),
      pane: .init(id: "pane", title: "Pane", cwd: "/tmp", focused: true)
    )
    let empty = LifecycleCommandPayload(resource: .tab, warnings: [], target: target)
    let emptyJSON = String(decoding: try JSONEncoder().encode(empty), as: UTF8.self)
    XCTAssertFalse(emptyJSON.contains("warnings"))

    let warning = LifecycleCommandWarning(
      code: .managedHookDegraded,
      runtime: "codex",
      message: "Resolver unavailable."
    )
    let decoded = try JSONDecoder().decode(
      LifecycleCommandPayload.self,
      from: JSONEncoder().encode(LifecycleCommandPayload(resource: .tab, warnings: [warning], target: target))
    )
    XCTAssertEqual(decoded.warnings, [warning])
  }

  private func assertValidity(_ instance: String, expected: Bool) throws {
    let schemaText = try XCTUnwrap(String(data: ProwlCLIContractBundle.schemaData, encoding: .utf8))
    let result = try Schema(instance: schemaText).validate(instance: instance)
    XCTAssertEqual(result.isValid, expected, "Schema errors: \(result.errors ?? [])")
  }
}
