import Foundation

/// Launch roles required by the start inputs. Runtime-dependent branches remain eligible.
nonisolated public enum WorkflowRoleRequirements {
  public static func launchRoles(
    in definition: WorkflowDefinition, inputs: [String: String], skipped: Set<String> = []
  ) -> Set<String> {
    let launchNames = Set(definition.roles.filter { $0.source == .launch }.map(\.name))
    var values: [String: WorkflowJSONValue] = [:]
    for input in definition.inputs {
      guard let value = inputs[input.name] ?? input.defaultValue?.stringValue else { continue }
      values[input.name] = input.type == .integer ? Int(value).map(WorkflowJSONValue.integer) : .string(value)
    }
    var required: Set<String> = []

    func expression(_ source: String) -> WorkflowExpressionNode? {
      var parser = try? WorkflowExpressionParser(source)
      return try? parser?.parse()
    }
    func recordReferences(_ node: WorkflowExpressionNode) {
      for path in node.references where path.first == "context" {
        if path.count == 1 || (path.count == 2 && path[1] == "roles") {
          required.formUnion(launchNames)
        } else if path.count > 2, path[1] == "roles" {
          required.insert(path[2])
        }
      }
    }
    func inputCondition(_ source: String) -> Bool? {
      guard let node = expression(source) else { return nil }
      recordReferences(node)
      guard node.references.allSatisfy({ $0.first == "inputs" }),
        case .boolean(let result) = try? node.evaluate(["inputs": .object(values)])
      else { return nil }
      return result
    }
    func templates(_ text: String) {
      var remaining = text[...]
      while let start = remaining.range(of: "{{") {
        remaining = remaining[start.upperBound...]
        guard let end = remaining.range(of: "}}") else { return }
        if let node = expression(String(remaining[..<end.lowerBound])) { recordReferences(node) }
        remaining = remaining[end.upperBound...]
      }
    }
    func json(_ value: WorkflowJSONValue) {
      switch value {
      case .string(let text): templates(text)
      case .array(let values): values.forEach(json)
      case .object(let values): values.values.forEach(json)
      default: break
      }
    }
    func actionInputs(_ id: String, _ inputs: [String: WorkflowJSONValue]) {
      inputs.values.forEach(json)
      for input in WorkflowActionRegistry.schema(for: id)?.inputs ?? [] where input.kind == .role {
        if case .string(let role) = inputs[input.name] { required.insert(role) }
      }
    }
    func visit(_ steps: [WorkflowStepDefinition]) {
      for step in steps where !skipped.contains(step.id) {
        if let title = step.title { templates(title) }
        switch step.action {
        case .launch(let role, let prompt, _, _):
          required.insert(role)
          templates(prompt)
        case .message(let role, let prompt, _):
          required.insert(role)
          templates(prompt)
        case .close(let role): required.insert(role)
        case .notify(let text): templates(text)
        case .action(let id, let inputs):
          actionInputs(id, inputs)
        case .control(.conditional(let condition, let thenSteps, let elseSteps)):
          if let result = inputCondition(condition) {
            visit(result ? thenSteps : elseSteps)
          } else {
            visit(thenSteps)
            visit(elseSteps)
          }
        case .control(.loop(let condition, _, let body)):
          if inputCondition(condition) != false { visit(body) }
        case .control(.set(let fields)):
          for source in fields.values {
            if let node = expression(source) { recordReferences(node) }
          }
        case .control(.breakLoop), .control(.continueLoop): break
        }
      }
    }
    visit(definition.steps)
    return required.intersection(launchNames)
  }
}
