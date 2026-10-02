import Foundation
import JSONSchema
import ProwlCLIContracts
import ProwlCLIShared
import XCTest

final class AgentReasonSchemaTests: XCTestCase {
  func testEncodedAgentReasonsMatchBothClosedSchemas() throws {
    let roster = AgentsCommandAgent(
      id: "pane", type: "codex", name: "Codex", status: .idle, rawState: "blocked",
      detectionReason: "screen.retainedCompletion", screenReason: "codex.confirmationFooter",
      lastChangedAt: "2026-09-12T00:00:00Z",
      project: .init(name: "Prowl", branch: "main", path: "/tmp/repo"),
      worktree: .init(id: "w", name: "main", path: "/tmp/repo", rootPath: "/tmp/repo", kind: "git"),
      tab: .init(id: "tab", title: "Terminal", selected: true),
      pane: .init(id: "pane", index: 1, title: "Codex", cwd: "/tmp/repo", focused: true))
    let read = AgentReadAgent(
      type: "codex", status: .idle, rawState: "blocked", detectionReason: "screen.retainedCompletion",
      screenReason: "codex.confirmationFooter", lastChangedAt: "2026-09-12T00:00:00Z", session: nil)
    for (reference, data) in [
      ("#/$defs/agent", try JSONEncoder().encode(roster)),
      ("#/$defs/agentReadData/properties/agent", try JSONEncoder().encode(read)),
    ] {
      var schema = try XCTUnwrap(
        JSONSerialization.jsonObject(with: ProwlCLIContractBundle.schemaData) as? [String: Any])
      schema.removeValue(forKey: "oneOf")
      schema["$ref"] = reference
      let schemaText = String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self)
      let validator = try Schema(instance: schemaText)
      let result = try validator.validate(instance: String(decoding: data, as: UTF8.self))
      XCTAssertTrue(result.isValid, "\(reference): \(result.errors ?? [])")
      var invalid = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      invalid["screen_reason"] = 42
      let bad = try validator.validate(
        instance: String(decoding: JSONSerialization.data(withJSONObject: invalid), as: UTF8.self))
      XCTAssertFalse(bad.isValid)
    }
  }
}
