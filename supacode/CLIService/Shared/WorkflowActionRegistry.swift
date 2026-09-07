// ProwlShared/WorkflowActionRegistry.swift
// Typed schemas of the V1 native actions (dsl-spec.md §4). The validator and `prowl workflow
// schema` read them; execution arrives with the runner.

import Foundation

nonisolated public struct WorkflowActionInput: Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    /// Templated text.
    case string
    /// Templated path.
    case path
    /// A role name declared by the workflow; never templated.
    case role
  }

  public let name: String
  public let required: Bool
  public let kind: Kind
  public let description: String

  public init(name: String, required: Bool, kind: Kind = .string, description: String) {
    self.name = name
    self.required = required
    self.kind = kind
    self.description = description
  }
}

nonisolated public struct WorkflowActionOutput: Equatable, Sendable {
  public let name: String
  public let description: String

  public init(name: String, description: String) {
    self.name = name
    self.description = description
  }
}

nonisolated public struct WorkflowActionSchema: Equatable, Sendable {
  public let id: String
  public let description: String
  public let inputs: [WorkflowActionInput]
  public let outputs: [WorkflowActionOutput]

  public init(id: String, description: String, inputs: [WorkflowActionInput], outputs: [WorkflowActionOutput]) {
    self.id = id
    self.description = description
    self.inputs = inputs
    self.outputs = outputs
  }

  public func input(named name: String) -> WorkflowActionInput? {
    inputs.first { $0.name == name }
  }

  public func hasOutput(named name: String) -> Bool {
    outputs.contains { $0.name == name }
  }
}

nonisolated public enum WorkflowActionRegistry {
  public static var worktreeContextInput: WorkflowActionJSONSchema {
    get throws {
      try WorkflowActionJSONSchema(
        .object([
          "type": "object", "properties": .object(["root": .object(["type": "string"])]),
          "additionalProperties": .boolean(false),
        ]), path: "builtin/collect-worktree-context-input.json")
    }
  }

  public static var worktreeContextOutput: WorkflowActionJSONSchema {
    get throws {
      try WorkflowActionJSONSchema(
        .object([
          "type": "object",
          "properties": .object([
            "path": .object(["type": "string"]), "branch": .object(["type": "string"]),
          ]), "required": .array(["path", "branch"]), "additionalProperties": .boolean(false),
        ]), path: "builtin/collect-worktree-context-output.json")
    }
  }

  public static let all: [WorkflowActionSchema] = [
    WorkflowActionSchema(
      id: "builtin:collect-worktree-context",
      description: "Save repository status and diff summary to this action's artifacts.",
      inputs: [
        WorkflowActionInput(
          name: "root", required: false, kind: .path,
          description: "Repository path within the selected worktree; defaults to the worktree")
      ],
      outputs: [
        WorkflowActionOutput(name: "output", description: "JSON object containing path and branch"),
        WorkflowActionOutput(name: "output_path", description: "Path to this invocation's result.json"),
      ])
  ]

  public static func schema(for id: String, in actions: [WorkflowActionSchema] = all) -> WorkflowActionSchema? {
    actions.first { $0.id == id }
  }
}
