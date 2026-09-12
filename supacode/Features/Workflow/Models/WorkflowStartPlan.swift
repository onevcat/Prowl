// supacode/Features/Workflow/Models/WorkflowStartPlan.swift
// What the start sheet explains about a workflow before any choice is made: who takes part
// (each role, how it is bound, and which steps address it) and what the run will do, step by
// step. Derived from the definition alone, so it is pure and testable; the sheet's pickers
// still come from the resolver's answers in `WorkflowStartContext`.

import Foundation
import ProwlCLIShared

nonisolated struct WorkflowStartPlan: Equatable, Sendable {
  struct Role: Equatable, Sendable, Identifiable {
    let name: String
    let source: WorkflowRoleSource
    /// The 1-based numbers (in `steps`) of the steps that message, launch, or close this role.
    let stepNumbers: [Int]
    /// The titles of those steps, in order, for the role row's caption.
    let stepTitles: [String]
    /// Where a `launch` role's pane opens; nil for the other sources.
    let placementNote: String?

    var id: String { name }

    /// "Author" — the YAML slug as a title.
    var title: String { WorkflowStartPlan.title(for: name) }

    /// The short tag next to the title: what kind of pane serves the role.
    var kindLabel: String {
      switch source {
      case .current: "This pane"
      case .launch: "New agent"
      case .pick: "Existing agent"
      }
    }

    /// One sentence for the row's tooltip.
    var kindDescription: String {
      switch source {
      case .current:
        "The pane you start the workflow from. Its agent receives this role's instructions."
      case .launch:
        "Prowl starts a new agent from an Agent Profile for this role."
      case .pick:
        "An agent that is already running in this worktree takes this role."
      }
    }

    /// "Step 1 · Prepare handoff briefing" or "Steps 2, 4 · Review, Review again".
    var stepsCaption: String? {
      guard !stepNumbers.isEmpty else { return nil }
      let numbers = stepNumbers.map(String.init).joined(separator: ", ")
      let prefix = stepNumbers.count == 1 ? "Step \(numbers)" : "Steps \(numbers)"
      return "\(prefix) · \(stepTitles.joined(separator: ", "))"
    }
  }

  struct Step: Equatable, Sendable, Identifiable {
    let id: String
    let number: Int
    let title: String
    /// The role a message, launch, or close addresses; nil for actions, notifications, controls.
    let role: String?
    let verb: String
    let context: WorkflowStartStepContext

    var roleTitle: String? { role.map(WorkflowStartPlan.title(for:)) }
  }

  let roles: [Role]
  let steps: [Step]

  init(definition: WorkflowDefinition) {
    var steps: [Step] = []
    func collect(_ list: [WorkflowStepDefinition], context: WorkflowStartStepContext) {
      for step in list {
        switch step.action {
        case .control(let control):
          switch control {
          case .conditional(_, let yes, let otherwise):
            collect(yes + otherwise, context: .conditional)
          case .loop(_, _, let body):
            collect(body, context: context == .conditional ? .conditional : .repeated)
          case .set, .breakLoop, .continueLoop:
            continue
          }
        case .message, .launch, .action, .notify, .close:
          steps.append(
            Step(
              id: step.id,
              number: steps.count + 1,
              title: step.title ?? step.historyTitle,
              role: step.action.targetRole,
              verb: step.action.verb,
              context: context))
        }
      }
    }
    collect(definition.steps, context: .always)
    self.steps = steps
    roles = definition.roles.map { role in
      let own = steps.filter { $0.role == role.name }
      return Role(
        name: role.name,
        source: role.source,
        stepNumbers: own.map(\.number),
        stepTitles: own.map(\.title),
        placementNote: role.launch.map(Self.placementNote))
    }
  }

  static func title(for slug: String) -> String {
    slug.replacing("_", with: " ").replacing("-", with: " ").prefix(1).uppercased()
      + slug.replacing("_", with: " ").replacing("-", with: " ").dropFirst()
  }

  private static func placementNote(_ launch: WorkflowLaunchRequirements) -> String {
    switch launch.placement {
    case .tab:
      return launch.background ? "Opens in a background tab" : "Opens in a new tab"
    case .split:
      let side =
        switch launch.direction {
        case .right: "right"
        case .left: "left"
        case .top: "top"
        case .down: "bottom"
        }
      return launch.background ? "Opens in a split on the \(side), unfocused" : "Opens in a split on the \(side)"
    }
  }
}

/// Where a step sits in the control flow, for the sheet's step list.
nonisolated enum WorkflowStartStepContext: Equatable, Sendable {
  case always
  /// Inside an `if` branch: runs only when its condition holds.
  case conditional
  /// Inside a `while` body: may run several times.
  case repeated
}
