// ProwlCLI/Output/OutputRenderer+Workflow.swift
// Text rendering for `prowl workflow`.

import Foundation
import ProwlCLIShared
@preconcurrency import Rainbow

extension OutputRenderer {
  static func renderWorkflow(_ payload: WorkflowCommandPayload) {
    switch payload {
    case .read(let content):
      if content.encoding == "base64" { print("Encoding: base64 (use --json for byte-preserving transfer)") }
      print(content.body)
      if let next = content.nextOffset {
        print("\nMore content: prowl workflow read \(content.resource) --run \(content.run) "
          + "--invocation \(content.invocation) --offset \(next)")
      }
      if !content.resources.isEmpty {
        print("\nAssigned resources:")
        for resource in content.resources { print("\(resource.id): \(resource.name)") }
      }
    case .list(let list):
      print(workflowListText(list))
    case .run(let run), .status(let run), .cancel(let run):
      print(workflowRunText(run))
    case .deliver(let deliver):
      print(workflowDeliverText(deliver))
    case .validate(let validate):
      print(workflowValidateText(validate))
    case .schema(let schema):
      renderWorkflowSchema(schema)
    }
  }

  static func workflowListText(_ payload: WorkflowListPayload) -> String {
    var lines: [String] = []
    if let worktree = payload.worktree {
      lines.append("Worktree: \(worktree.name.bold)  \(worktree.path.dim)")
    }
    lines.append(
      "Sources: bundle \(payload.sources.bundle ?? "—")  user \(payload.sources.user)  repo \(payload.sources.repo ?? "—")"
        .dim)
    guard !payload.workflows.isEmpty else {
      lines.append("No workflow definitions found.")
      return lines.joined(separator: "\n")
    }
    lines.append("")
    for entry in payload.workflows {
      let id = entry.id ?? "(unparsed)"
      let name = entry.name.map { "  \($0)" } ?? ""
      var flags: [String] = []
      flags.append(entry.valid ? "valid".green : "invalid".red)
      if entry.warnings > 0 { flags.append("\(entry.warnings) warning(s)".yellow) }
      if entry.errors > 0 { flags.append("\(entry.errors) error(s)".red) }
      if !entry.enabled { flags.append("disabled".dim) }
      if entry.shadowed { flags.append("shadowed".dim) }
      lines.append("\(id.bold)\(name)  [\(entry.scope.rawValue)]  \(flags.joined(separator: "  "))")
      lines.append("  \(entry.path.dim)")
    }
    return lines.joined(separator: "\n")
  }

  static func workflowRunText(_ payload: WorkflowRunPayload) -> String {
    var lines = [
      "Run: \(payload.id.bold)  \(payload.workflow.id) (\(payload.workflow.name))  [\(payload.source.rawValue)]"
    ]
    lines.append("Status: \(workflowStatusText(payload.status))")
    if let step = payload.step {
      var line = "Step: \(step)"
      if let activation = payload.activation {
        line +=
          "  waiting for '\(activation.role)' → delivery '\(activation.delivery)' (\(activation.state))"
      }
      lines.append(line)
    }
    if let role = payload.role {
      lines.append("Your role: \(role.bold)")
    }
    if let activation = payload.activation, !activation.expect.completion.isEmpty {
      lines.append("Finish with: \(activation.expect.completion.joined(separator: "  or  "))")
    }
    lines.append("Worktree: \(payload.worktree.name)  \(payload.worktree.path.dim)")
    lines.append("Run directory: \(payload.runDirectory.dim)")
    if !payload.bindings.isEmpty {
      lines.append("Bindings:")
      for (role, binding) in payload.bindings.sorted(by: { $0.key < $1.key }) {
        var parts = ["  \(role.bold)  \(binding.source.rawValue)"]
        if let profile = binding.profile {
          parts.append("\(profile.name) (\(profile.agent))")
        }
        if let pane = binding.pane {
          let agent = pane.agent.map { " (\($0))" } ?? ""
          parts.append("\(pane.handle) \(pane.displayName)\(agent)")
        }
        lines.append(parts.joined(separator: "  "))
      }
    }
    if !payload.deliveries.isEmpty {
      lines.append("Deliveries:")
      for (name, output) in payload.deliveries.sorted(by: { $0.key < $1.key }) {
        let verdict = output.verdict.map { "  verdict \($0)" } ?? ""
        lines.append("  \(name.bold)  \(output.latestPath.dim)\(verdict)")
      }
    }
    if let selfInitiated = payload.selfInitiated {
      lines.append("This pane is the current role; nothing was typed. Follow this line yourself:")
      lines.append("  \(selfInitiated.line)")
    }
    return lines.joined(separator: "\n")
  }

  static func workflowDeliverText(_ payload: WorkflowDeliverPayload) -> String {
    let delivery = payload.delivery
    var lines: [String] = []
    switch delivery.state {
    case .delivered:
      lines.append(
        "\("Delivered".green)  delivery '\(delivery.record.name)' for step '\(delivery.step)' (invocation \(delivery.ordinal))"
      )
    case .provisional:
      lines.append(
        "\("Provisional".yellow)  delivery '\(delivery.record.name)' for step '\(delivery.step)' is on disk but needs a decision in Prowl:"
      )
      for warning in delivery.warnings {
        lines.append("  - \(warning.message) [\(warning.code)]")
      }
    }
    lines.append("  \(delivery.record.path.dim)")
    lines.append("Run: \(payload.run.id)  \(workflowStatusText(payload.run.status))")
    return lines.joined(separator: "\n")
  }

  private static func workflowStatusText(_ status: WorkflowRunStatusPayload) -> String {
    switch status.state {
    case "running": return "running".green
    case "needs_attention":
      let detail = status.attention.map { " — \($0.message)" } ?? ""
      return "needs attention".yellow + detail
    case "completed": return "completed".green
    case "skipped":
      let detail = [status.step, status.dependent].compactMap { $0 }.joined(separator: " → ")
      return "skipped".yellow + (detail.isEmpty ? "" : " (\(detail))")
    case "cancelled", "interrupted", "iteration_limit_reached":
      return status.state.replacing("_", with: " ").red
    default: return status.state
    }
  }

  static func workflowValidateText(_ payload: WorkflowValidatePayload) -> String {
    var lines = payload.diagnostics.map { diagnostic in
      let position =
        diagnostic.line.map { line in
          ":\(line)" + (diagnostic.column.map { ":\($0)" } ?? "")
        } ?? ""
      let severity = diagnostic.severity == .error ? "error".red : "warning".yellow
      return "\(payload.path)\(position): \(severity)[\(diagnostic.code)]: \(diagnostic.message)"
    }
    let errors = payload.diagnostics.filter { $0.severity == .error }.count
    let warnings = payload.diagnostics.count - errors
    let identity = payload.workflow.map { "\($0.id) (\($0.name))" } ?? payload.path
    if payload.valid {
      lines.append(
        "\("OK".green)  \(identity)\(warnings > 0 ? "  \(warnings) warning(s)".yellow : "")")
    } else {
      lines.append("\("INVALID".red)  \(identity)  \(errors) error(s), \(warnings) warning(s)")
    }
    return lines.joined(separator: "\n")
  }

  private static func renderWorkflowSchema(_ payload: WorkflowSchemaPayload) {
    if let object = try? JSONSerialization.jsonObject(with: payload.schema.bytes),
      let pretty = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    {
      FileHandle.standardOutput.write(pretty)
      FileHandle.standardOutput.write(Data([UInt8(ascii: "\n")]))
      return
    }
    FileHandle.standardOutput.write(payload.schema.bytes)
  }
}
