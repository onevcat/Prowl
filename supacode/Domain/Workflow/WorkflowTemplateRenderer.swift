// supacode/Domain/Workflow/WorkflowTemplateRenderer.swift
// Substitution of the dsl-spec §6 whitelist over a typed context. Substituted values are never
// re-scanned, and a reference to a skipped output is the runtime side of the §5 Skip rule.

import Foundation
import ProwlCLIShared

nonisolated struct WorkflowTemplateContext: Equatable, Sendable {
  struct Run: Equatable, Sendable {
    let id: String
    let directory: String
  }

  struct Worktree: Equatable, Sendable {
    let path: String
    let name: String
    let branch: String
  }

  struct Role: Equatable, Sendable {
    let name: String
    let agent: String
    /// The pane short handle (`p12`); nil until a launch role is launched.
    let pane: String?
  }

  struct Output: Equatable, Sendable {
    let path: String
    let verdict: String?
  }

  struct Loop: Equatable, Sendable {
    /// 1-based iteration; nil outside a `repeat`.
    let index: Int?
    /// Iterations completed by the latest loop.
    let count: Int
  }

  var run: Run
  var worktree: Worktree
  var roles: [String: Role]
  /// Latest delivered output per name.
  var outputs: [String: Output]
  var skippedOutputs: Set<String>
  var actions: [String: [String: String]]
  var inputs: [String: String]
  var loop: Loop

  init(
    run: Run,
    worktree: Worktree,
    roles: [String: Role],
    outputs: [String: Output],
    skippedOutputs: Set<String> = [],
    actions: [String: [String: String]] = [:],
    inputs: [String: String] = [:],
    loop: Loop = Loop(index: nil, count: 0)
  ) {
    self.run = run
    self.worktree = worktree
    self.roles = roles
    self.outputs = outputs
    self.skippedOutputs = skippedOutputs
    self.actions = actions
    self.inputs = inputs
    self.loop = loop
  }
}

nonisolated enum WorkflowTemplateError: Error, Equatable, Sendable {
  case malformed(WorkflowTemplate.ScanError)
  case unknownVariable(String)
  /// The output was skipped or never delivered: the consumer cannot render (§5 Skip rule).
  case missingOutput(name: String)
  case verdictUnavailable(output: String)
  case paneUnavailable(role: String)
}

extension WorkflowTemplate {
  nonisolated static func render(_ text: String, context: WorkflowTemplateContext) throws(WorkflowTemplateError)
    -> String
  {
    guard containsReference(text) else { return text }
    let references: [Reference]
    do {
      references = try Self.references(in: text)
    } catch {
      throw .malformed(error)
    }
    var rendered = ""
    var remainder = Substring(text)
    for reference in references {
      guard let range = remainder.firstRange(of: "{{"),
        let close = remainder[range.upperBound...].firstRange(of: "}}")
      else { break }
      rendered += remainder[..<range.lowerBound]
      rendered += try value(for: reference, context: context)
      remainder = remainder[close.upperBound...]
    }
    rendered += remainder
    return rendered
  }

  nonisolated static func value(for reference: Reference, context: WorkflowTemplateContext)
    throws(WorkflowTemplateError) -> String
  {
    let parts = reference.components
    let value: String? =
      switch (parts.first, parts.count) {
      case ("run", 2): runValue(parts[1], context: context)
      case ("worktree", 2): worktreeValue(parts[1], context: context)
      case ("inputs", 2): context.inputs[parts[1]]
      case ("loop", 2): loopValue(parts[1], context: context)
      case ("roles", 3): try roleValue(parts[1], field: parts[2], context: context)
      case ("outputs", 3): try outputValue(parts[1], field: parts[2], context: context)
      case ("actions", 3): context.actions[parts[1]]?[parts[2]]
      default: nil
      }
    guard let value else { throw .unknownVariable(reference.path) }
    return value
  }

  private nonisolated static func runValue(_ field: String, context: WorkflowTemplateContext) -> String? {
    switch field {
    case "id": context.run.id
    case "dir": context.run.directory
    default: nil
    }
  }

  private nonisolated static func worktreeValue(_ field: String, context: WorkflowTemplateContext) -> String? {
    switch field {
    case "path": context.worktree.path
    case "name": context.worktree.name
    case "branch": context.worktree.branch
    default: nil
    }
  }

  private nonisolated static func loopValue(_ field: String, context: WorkflowTemplateContext) -> String? {
    switch field {
    case "index": context.loop.index.map(String.init)
    case "count": String(context.loop.count)
    default: nil
    }
  }

  private nonisolated static func roleValue(
    _ role: String, field: String, context: WorkflowTemplateContext
  ) throws(WorkflowTemplateError) -> String? {
    guard let binding = context.roles[role] else { return nil }
    switch field {
    case "name": return binding.name
    case "agent": return binding.agent
    case "pane":
      guard let pane = binding.pane else { throw .paneUnavailable(role: role) }
      return pane
    default: return nil
    }
  }

  private nonisolated static func outputValue(
    _ name: String, field: String, context: WorkflowTemplateContext
  ) throws(WorkflowTemplateError) -> String? {
    guard ["path", "verdict"].contains(field) else { return nil }
    guard !context.skippedOutputs.contains(name), let output = context.outputs[name] else {
      throw .missingOutput(name: name)
    }
    if field == "path" { return output.path }
    guard let verdict = output.verdict else { throw .verdictUnavailable(output: name) }
    return verdict
  }
}
