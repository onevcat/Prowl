import Foundation

nonisolated public struct WorkflowLoopLimit: Error, Equatable, Sendable {
  public let stepID: String
}

/// A sequential stack interpreter. External work pauses at a step until `complete` is called.
nonisolated public struct WorkflowControlCursor: Equatable, Sendable {
  public enum Outcome: Equatable, Sendable {
    case step(WorkflowStepDefinition)
    case yielded
    case finished
  }

  private struct Frame: Equatable, Sendable {
    var steps: [WorkflowStepDefinition]
    var index = 0
    var loop: WorkflowStepDefinition?
    var iteration = 0
  }

  public struct Evaluation: Equatable, Sendable {
    public let stepID: String
    public let iteration: Int?
    public let skipped: Bool
  }

  public private(set) var evaluations: [Evaluation] = []
  private var frames: [Frame]
  public private(set) var state: WorkflowTypedState
  public private(set) var expiredOutputs: Set<String> = []
  public private(set) var expiredActions: Set<String> = []
  public private(set) var currentStep: WorkflowStepDefinition?
  public var remainingSteps: [WorkflowStepDefinition] {
    frames.reversed().flatMap { frame in
      Array(frame.steps.dropFirst(frame.index)) + (frame.loop.map { [$0] } ?? [])
    }
  }
  public var isFinished: Bool { frames.isEmpty }
  public var iteration: Int? { frames.last(where: { $0.loop != nil })?.iteration }

  public init(definition: WorkflowDefinition) throws {
    state = try WorkflowTypedState(declarations: definition.state)
    frames = [Frame(steps: definition.steps)]
  }

  public func values(over context: [String: WorkflowJSONValue]) -> [String: WorkflowJSONValue] {
    var result = context
    result["state"] = Self.object(state.values)
    for (group, expired) in [("deliveries", expiredOutputs), ("actions", expiredActions)] {
      if case .object(var fields) = result[group] {
        for name in expired { fields.removeValue(forKey: name) }
        result[group] = .object(fields)
      }
    }
    return result
  }

  public mutating func next(values context: [String: WorkflowJSONValue], budget: Int = 64) throws -> Outcome {
    evaluations = []
    if let currentStep { return .step(currentStep) }
    for _ in 0..<max(1, budget) {
      guard let frame = frames.last else { return .finished }
      if frame.index >= frame.steps.count {
        try endFrame(context: context)
        continue
      }
      let step = frame.steps[frame.index]
      guard case .control(let control) = step.action else {
        currentStep = step
        return .step(step)
      }
      let position = if case .loop = control { 0 } else { iteration }
      let stepContext = Self.positioned(context, stepID: step.id, iteration: position)
      let currentIteration = iteration
      try execute(control, step: step, context: stepContext)
      evaluations.append(Evaluation(stepID: step.id, iteration: currentIteration, skipped: false))
    }
    return frames.isEmpty ? .finished : .yielded
  }

  public mutating func complete() {
    guard let step = currentStep, !frames.isEmpty else { return }
    if case .action = step.action { expiredActions.remove(step.id) }
    if let output = step.deliveryName { expiredOutputs.remove(output) }
    frames[frames.count - 1].index += 1
    currentStep = nil
  }

  private mutating func execute(
    _ control: WorkflowControlStep, step: WorkflowStepDefinition, context: [String: WorkflowJSONValue]
  ) throws {
    switch control {
    case .set(let assignments):
      try state.assign(assignments, values: values(over: context))
      frames[frames.count - 1].index += 1
    case .conditional(let condition, let yes, let otherwise):
      let selected = try conditionValue(condition, context: context)
      let branch = selected ? yes : otherwise
      recordSkipped(selected ? otherwise : yes)
      frames[frames.count - 1].index += 1
      expire(step.action.children)
      frames.append(Frame(steps: branch))
    case .loop(let condition, let maximum, let body):
      frames[frames.count - 1].index += 1
      expire(body)
      if try conditionValue(condition, context: context) {
        if let maximum, maximum <= 0 { throw WorkflowLoopLimit(stepID: step.id) }
        frames.append(Frame(steps: body, loop: step, iteration: 1))
      } else {
        recordSkipped(body)
      }
    case .breakLoop, .continueLoop:
      guard let loopIndex = frames.lastIndex(where: { $0.loop != nil }) else {
        throw WorkflowExpressionError.type("Loop control requires an enclosing loop.")
      }
      while frames.count - 1 > loopIndex { expire(frames.removeLast().steps) }
      if case .breakLoop = control {
        expire(frames.removeLast().steps)
      } else {
        frames[loopIndex].index = frames[loopIndex].steps.count
      }
    }
  }

  private mutating func endFrame(context: [String: WorkflowJSONValue]) throws {
    guard let frame = frames.last else { return }
    if let loop = frame.loop, case .control(.loop(let condition, let maximum, _)) = loop.action {
      expire(frame.steps)
      let loopContext = Self.positioned(context, stepID: loop.id, iteration: frame.iteration)
      if try conditionValue(condition, context: loopContext) {
        if let maximum, frame.iteration >= maximum {
          throw WorkflowLoopLimit(stepID: loop.id)
        }
        guard frame.iteration < WorkflowJSON.maximumInteger else {
          throw WorkflowExpressionError.limit("Loop iteration counter overflow.")
        }
        frames[frames.count - 1].index = 0
        frames[frames.count - 1].iteration += 1
        return
      }
    }
    if frames.count > 1 { expire(frame.steps) }
    frames.removeLast()
  }

  private static func positioned(
    _ context: [String: WorkflowJSONValue], stepID: String, iteration: Int?
  ) -> [String: WorkflowJSONValue] {
    var result = context
    if case .object(var fields) = result["context"], case .object(var position) = fields["step"] {
      position["id"] = .string(stepID)
      position["iteration"] = iteration.map(WorkflowJSONValue.integer) ?? .null
      fields["step"] = .object(position)
      result["context"] = .object(fields)
    }
    return result
  }

  private func conditionValue(_ expression: String, context: [String: WorkflowJSONValue]) throws -> Bool {
    guard case .boolean(let value) = try WorkflowExpression.evaluate(expression, values: values(over: context)) else {
      throw WorkflowExpressionError.type("Control condition must be boolean.")
    }
    return value
  }

  private mutating func recordSkipped(_ steps: [WorkflowStepDefinition]) {
    for step in steps {
      evaluations.append(Evaluation(stepID: step.id, iteration: iteration, skipped: true))
      recordSkipped(step.action.children)
    }
  }

  private mutating func expire(_ steps: [WorkflowStepDefinition]) {
    for step in steps {
      if case .action = step.action { expiredActions.insert(step.id) }
      if let output = step.deliveryName { expiredOutputs.insert(output) }
      expire(step.action.children)
    }
  }

  private static func object(_ values: [String: WorkflowJSONValue]) -> WorkflowJSONValue {
    var object = WorkflowJSONValue.object([:])
    if case .object(var fields) = object {
      for (key, value) in values { fields[key] = value }
      object = .object(fields)
    }
    return object
  }
}
