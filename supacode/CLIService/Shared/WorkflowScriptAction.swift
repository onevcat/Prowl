import Foundation
import Yams

nonisolated public struct WorkflowScriptAction: Equatable, Sendable {
  public let id: String
  public let name: String
  public let interpreter: String
  public let entrypoint: String
  public let arguments: [String]
  public let inheritedEnvironmentNames: [String]
  public let timeoutSeconds: Int
  public let inputSchema: WorkflowJSONValue
  public let outputSchema: WorkflowJSONValue
  private let inputContract: WorkflowActionJSONSchema
  private let outputContract: WorkflowActionJSONSchema

  public static func parse(_ yaml: String, id: String, files: [String: Data] = [:]) throws -> Self {
    let document = try WorkflowYAMLValue.parse(yaml)
    guard case .object(let root) = document else { throw WorkflowExpressionError.type("Action must be a mapping.") }
    try checkKeys(root.keys, allowed: ["schema", "name", "input_schema", "output_schema", "backend", "timeout"])
    guard root["schema"] == .string("prowl.action/v1"), WorkflowSchema.isActionID(id),
      case .string(let name) = root["name"], !name.isEmpty,
      case .object(let backend) = root["backend"], backend["type"] == .string("script"),
      case .string(let interpreter) = backend["interpreter"], !interpreter.isEmpty,
      case .string(let entrypoint) = backend["entrypoint"], safeRelativePath(entrypoint),
      let input = root["input_schema"], let output = root["output_schema"]
    else { throw WorkflowExpressionError.type("Action requires schema, name, object schemas, and a script backend.") }
    try checkKeys(backend.keys, allowed: ["type", "interpreter", "entrypoint", "arguments", "inherit_env"])
    guard !interpreter.contains("{{"), !interpreter.contains("\n"), !interpreter.contains("\0") else {
      throw WorkflowExpressionError.type("Interpreter must be literal executable text.")
    }
    let arguments = try strings(backend["arguments"])
    let inheritedEnvironmentNames = try strings(backend["inherit_env"])
    for name in inheritedEnvironmentNames {
      guard name.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil, !name.hasPrefix("PROWL_") else {
        throw WorkflowExpressionError.type("Invalid inherited environment name: \(name).")
      }
    }
    let timeout: Int
    if let value = root["timeout"] {
      guard case .string(let text) = value, text.hasSuffix("s"), let seconds = Int(text.dropLast()),
        (1...86_400).contains(seconds)
      else { throw WorkflowExpressionError.type("Action timeout must be 1s...86400s.") }
      timeout = seconds
    } else {
      timeout = 30
    }
    let inputContract = try WorkflowActionJSONSchema(input, path: "actions/\(id)/input.schema.json", files: files)
    let outputContract = try WorkflowActionJSONSchema(output, path: "actions/\(id)/output.schema.json", files: files)
    return Self(
      id: id, name: name, interpreter: interpreter, entrypoint: entrypoint, arguments: arguments,
      inheritedEnvironmentNames: inheritedEnvironmentNames, timeoutSeconds: timeout, inputSchema: input,
      outputSchema: output,
      inputContract: inputContract, outputContract: outputContract)
  }

  public func validateInput(_ value: WorkflowJSONValue) throws { try inputContract.validate(value) }
  public func validateOutput(_ value: WorkflowJSONValue) throws { try outputContract.validate(value) }

  public static func safeRelativePath(_ path: String) -> Bool {
    !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0")
      && !path.contains("{{")
      && path.split(separator: "/", omittingEmptySubsequences: false)
        .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  private static func strings(_ value: WorkflowJSONValue?) throws -> [String] {
    guard let value else { return [] }
    guard case .array(let array) = value else { throw WorkflowExpressionError.type("Expected a string array.") }
    return try array.map {
      guard case .string(let text) = $0, !text.contains("\0"), !text.contains("{{") else {
        throw WorkflowExpressionError.type("Expected literal strings without null characters.")
      }
      return text
    }
  }

  private static func checkKeys(_ keys: some Sequence<String>, allowed: Set<String>) throws {
    for key in keys where !allowed.contains(key) { throw WorkflowExpressionError.type("Unknown action key: \(key).") }
  }

}
