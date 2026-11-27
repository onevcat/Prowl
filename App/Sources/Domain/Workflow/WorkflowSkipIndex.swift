import ProwlCLIShared

/// What the Skip rule reads from a definition, computed one time.
///
/// The rule asks "which step requires this delivery" for one step after another. The start
/// sheet asks it for every optional step on each refresh, so the steps must not be flattened
/// and their templates must not be parsed again for each question.
nonisolated struct WorkflowSkipIndex: Equatable, Sendable {
  /// Step id → the delivery that the step produces. Only a step with an `expect` has one.
  private let deliveryByStep: [String: String]
  /// Step id → the deliveries that the step's own templates and expressions require. A control
  /// step's entry holds its conditions and assignments, not the steps inside it.
  private let requiredDeliveriesByStep: [String: Set<String>]

  init(definition: WorkflowDefinition) {
    var deliveryByStep: [String: String] = [:]
    var requiredDeliveriesByStep: [String: Set<String>] = [:]
    for step in definition.flattenedSteps {
      if let delivery = step.deliveryName, deliveryByStep[step.id] == nil { deliveryByStep[step.id] = delivery }
      let required = Self.deliveries(requiredBy: step)
      if !required.isEmpty { requiredDeliveriesByStep[step.id, default: []].formUnion(required) }
    }
    self.deliveryByStep = deliveryByStep
    self.requiredDeliveriesByStep = requiredDeliveriesByStep
  }

  func delivery(ofStep stepID: String) -> String? { deliveryByStep[stepID] }

  func step(_ stepID: String, requires delivery: String) -> Bool {
    requiredDeliveriesByStep[stepID]?.contains(delivery) ?? false
  }

  private static func deliveries(requiredBy step: WorkflowStepDefinition) -> Set<String> {
    var result: Set<String> = []
    if let title = step.title { result.formUnion(deliveries(in: title)) }
    switch step.action {
    case .message(_, let prompt, _), .launch(_, let prompt, _, _):
      result.formUnion(deliveries(in: prompt))
    case .notify(let text):
      result.formUnion(deliveries(in: text))
    case .close:
      break
    case .action(_, let inputs):
      for value in inputs.values { result.formUnion(deliveries(in: value)) }
    case .control(let control):
      let expressions: [String]
      switch control {
      case .set(let assignments): expressions = Array(assignments.values)
      case .conditional(let condition, _, _), .loop(let condition, _, _): expressions = [condition]
      case .breakLoop, .continueLoop: expressions = []
      }
      for expression in expressions { result.formUnion(deliveries(in: "{{ " + expression + " }}")) }
    }
    return result
  }

  /// A text that does not parse requires nothing: the validator reports it, and the run stops on it.
  private static func deliveries(in text: String) -> Set<String> {
    guard let paths = try? WorkflowExpression.requiredReferences(in: text) else { return [] }
    return Set(paths.compactMap { $0.count >= 2 && $0[0] == "deliveries" ? $0[1] : nil })
  }

  private static func deliveries(in value: WorkflowJSONValue) -> Set<String> {
    switch value {
    case .string(let text): deliveries(in: text)
    case .array(let items): items.reduce(into: []) { $0.formUnion(deliveries(in: $1)) }
    case .object(let fields): fields.values.reduce(into: []) { $0.formUnion(deliveries(in: $1)) }
    default: []
    }
  }
}
