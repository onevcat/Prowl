import Foundation
import ProwlCLIShared

extension WorkflowRun {
  nonisolated func expressionValues(capturedAt: Date) -> [String: WorkflowJSONValue] {
    let timestamp = capturedAt.ISO8601Format()
    let roles = bindings.mapValues { binding -> WorkflowJSONValue in
      let observed = binding.pane.flatMap { observations[$0.surfaceID.uuidString] }
      return .object([
        "source": .string(binding.source.rawValue),
        "display_name": .string(binding.displayName),
        "agent": .string(binding.agent),
        "pane_id": binding.pane.map { .string($0.surfaceID.uuidString) } ?? .null,
        "observed": observed ?? .null,
      ])
    }
    let outputValues = deliveries.mapValues { output -> WorkflowJSONValue in
      .object(["path": .string(output.latestPath), "verdict": output.verdict.map(WorkflowJSONValue.string) ?? .null])
    }
    var typedInputs: [String: WorkflowJSONValue] = [:]
    for (name, value) in inputs {
      if definition.input(named: name)?.type == .integer, let number = Int(value) {
        typedInputs[name] = .integer(number)
      } else {
        typedInputs[name] = .string(value)
      }
    }
    let contextValue: WorkflowJSONValue = .object([
      "workflow": .object(["id": .string(definition.id), "name": .string(definition.name)]),
      "run": .object(["id": .string(id.uuidString), "path": .string(runDirectory.path)]),
      "worktree": .object([
        "id": .string(context.worktree.id), "path": .string(context.worktree.path),
        "name": .string(context.worktree.name), "branch": observations["branch"] ?? .string(context.worktree.branch),
        "captured_at": .string(timestamp),
      ]),
      "initiator": (context.sourcePaneID ?? bindings.values.first { $0.source == .current }?.pane?.surfaceID).map {
        .object([
          "pane_id": .string($0.uuidString),
          "tab_id": (context.sourceTabID ?? bindings.values.first { $0.source == .current }?.pane?.tabID)
            .map { .string($0.uuidString) } ?? .null,
        ])
      } ?? .null,
      "roles": WorkflowJSON.object(roles),
      "step": .object([
        "id": currentStep.map { .string($0.id) } ?? .null,
        "iteration": currentIteration.map(WorkflowJSONValue.integer) ?? .null,
        "captured_at": .string(timestamp),
      ]),
    ])
    let values = [
      "context": contextValue, "inputs": WorkflowJSON.object(typedInputs),
      "deliveries": WorkflowJSON.object(outputValues),
      "actions": WorkflowJSON.object(actionOutputs.mapValues(WorkflowJSON.object)),
    ]
    return controlCursor?.values(over: values) ?? values
  }
}
