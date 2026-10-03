import Foundation
import JSONSchema
import ProwlCLIContracts
import ProwlCLIShared
import XCTest

final class AgentSignalSchemaTests: XCTestCase {
  func testAgentSignalSchemaAcceptsBindingAndUnboundWarning() throws {
    let bound = #"{"ok":true,"command":"agents.signal","schema_version":"prowl.cli.agents.signal.v1","data":{"pane":{"id":"D2719F02-5F27-4D46-A62F-0FAF49410D4D","worktree_id":"wt"},"signal":{"event":"turn-ended","source":"cooperative_cli","confidence":"exact","binding":"current","at":"2026-08-24T00:00:00.000Z"}}}"#
    let unbound = #"{"ok":true,"command":"agents.signal","schema_version":"prowl.cli.agents.signal.v1","data":{"pane":{"id":"D2719F02-5F27-4D46-A62F-0FAF49410D4D","worktree_id":"wt"},"signal":{"event":"needs-input","source":"cooperative_cli","confidence":"exact","binding":"unbound","at":"2026-08-24T00:00:00.000Z"},"warnings":[{"code":"signal_unbound","message":"Recorded as diagnostic only."}]}}"#
    let staleBinding = bound.replacingOccurrences(of: #""binding":"current""#, with: #""binding":"stale""#)
    let unknownWarningField = unbound.replacingOccurrences(
      of: #""message":"Recorded as diagnostic only.""#,
      with: #""message":"Recorded as diagnostic only.","runtime":"claude""#
    )
    let emptyWarnings = bound.replacingOccurrences(of: #"}}}"#, with: #"},"warnings":[]}}"#)

    try assertValidity(bound, expected: true)
    try assertValidity(unbound, expected: true)
    try assertValidity(staleBinding, expected: false)
    try assertValidity(unknownWarningField, expected: false)
    try assertValidity(emptyWarnings, expected: false)
  }

  func testAgentSignalSchemaRequiresBindingAndPairsUnboundWithItsWarning() throws {
    let bound = #"{"ok":true,"command":"agents.signal","schema_version":"prowl.cli.agents.signal.v1","data":{"pane":{"id":"D2719F02-5F27-4D46-A62F-0FAF49410D4D","worktree_id":"wt"},"signal":{"event":"turn-ended","source":"cooperative_cli","confidence":"exact","binding":"current","at":"2026-08-24T00:00:00.000Z"}}}"#
    let missingBinding = bound.replacingOccurrences(of: #""binding":"current","#, with: "")
    let unboundWithoutWarning = bound.replacingOccurrences(of: #""binding":"current""#, with: #""binding":"unbound""#)
    let currentWithWarning = bound.replacingOccurrences(
      of: #"}}}"#,
      with: #"},"warnings":[{"code":"signal_unbound","message":"Recorded as diagnostic only."}]}}"#
    )

    try assertValidity(missingBinding, expected: false)
    try assertValidity(unboundWithoutWarning, expected: false)
    try assertValidity(currentWithWarning, expected: false)
  }

  func testSignalPayloadOmitsEmptyWarningsAndRoundTripsBinding() throws {
    let signal = AgentSignalPayload(
      event: .needsInput,
      progress: nil,
      source: "cooperative_cli",
      confidence: "exact",
      binding: .unbound,
      timestamp: "2026-08-24T00:00:00.000Z",
      sessionID: nil,
      detail: nil,
      claimedOrigin: nil
    )
    let pane = AgentSignalPanePayload(id: "pane", worktreeID: "wt")
    let empty = AgentSignalCommandPayload(pane: pane, signal: signal, warnings: [])
    let emptyJSON = String(decoding: try JSONEncoder().encode(empty), as: UTF8.self)
    XCTAssertFalse(emptyJSON.contains("warnings"))
    XCTAssertTrue(emptyJSON.contains(#""binding":"unbound""#))

    let warning = AgentSignalWarning(code: .signalUnbound, message: "Recorded as diagnostic only.")
    let decoded = try JSONDecoder().decode(
      AgentSignalCommandPayload.self,
      from: JSONEncoder().encode(AgentSignalCommandPayload(pane: pane, signal: signal, warnings: [warning]))
    )
    XCTAssertEqual(decoded.warnings, [warning])
    XCTAssertEqual(decoded.signal.binding, .unbound)
  }

  private func assertValidity(_ instance: String, expected: Bool) throws {
    let schemaText = try XCTUnwrap(String(data: ProwlCLIContractBundle.schemaData, encoding: .utf8))
    let result = try Schema(instance: schemaText).validate(instance: instance)
    XCTAssertEqual(result.isValid, expected, "Schema errors: \(result.errors ?? [])")
  }
}
