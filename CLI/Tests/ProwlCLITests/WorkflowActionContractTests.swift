import Foundation
import Testing
@testable import ProwlCLIShared

struct WorkflowActionContractTests {
  private let yaml = """
    schema: prowl.action/v1
    name: Count
    input_schema:
      type: object
      properties:
        count: {type: integer}
      required: [count]
      additionalProperties: false
    output_schema:
      type: object
      properties:
        ok: {type: boolean}
      required: [ok]
      additionalProperties: false
    backend:
      type: script
      interpreter: python3
      entrypoint: main.py
    timeout: 30s
    """

  @Test func scriptEnvironmentDisablesBytecodeAndKeepsOnlyAllowedValues() throws {
    let source = yaml.replacing("entrypoint: main.py", with:
      "entrypoint: main.py\n  inherit_env: [SELECTED_VALUE, PYTHONDONTWRITEBYTECODE]")
    let action = try WorkflowScriptAction.parse(source, id: "count")
    let environment = WorkflowPreparedBundle.environment(for: action, inherited: [
      "PATH": "/usr/bin:/bin", "SELECTED_VALUE": "included", "UNSELECTED_VALUE": "excluded",
      "PROWL_WORKFLOW_TOKEN": "excluded", "PYTHONDONTWRITEBYTECODE": "",
    ])
    #expect(environment == [
      "PATH": "/usr/bin:/bin", "SELECTED_VALUE": "included", "PYTHONDONTWRITEBYTECODE": "1",
    ])
  }

  @Test func validatesTypesWithoutApplyingDefaults() throws {
    let contract = try WorkflowScriptAction.parse(yaml, id: "count")
    try contract.validateInput(.object(["count": .integer(3)]))
    #expect(throws: (any Error).self) { try contract.validateInput(.object(["count": .string("3")])) }
    #expect(throws: (any Error).self) { try contract.validateOutput(.object(["ok": .string("true")])) }
    #expect(throws: (any Error).self) { try contract.validateOutput(.array([])) }
  }

  @Test func rejectsUnknownKeysUnsafeEntrypointsAndRemoteReferences() {
    for invalid in [
      yaml + "\nunknown: true\n",
      yaml.replacing("entrypoint: main.py", with: "entrypoint: ../main.py"),
      yaml.replacing("type: integer", with: "$ref: https://example.com/schema"),
      yaml.replacing("type: integer", with: "type: imaginary"),
    ] {
      #expect(throws: (any Error).self) { try WorkflowScriptAction.parse(invalid, id: "count") }
    }
  }
  @Test func resolvesPackageSchemasWithoutNetworkAccess() throws {
    let source = yaml.replacing("count: {type: integer}", with: "count: {$ref: ../../schemas/count.json}")
    let action = try WorkflowScriptAction.parse(source, id: "count", files: [
      "schemas/count.json": Data(#"{"type":"integer","minimum":1}"#.utf8)
    ])
    try action.validateInput(.object(["count": .integer(2)]))
    #expect(throws: (any Error).self) { try action.validateInput(.object(["count": .integer(0)])) }
    #expect(throws: (any Error).self) { try WorkflowScriptAction.parse(source, id: "count") }
  }

}
