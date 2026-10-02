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
    public var path: [String] = []
    public var title: String?
    public var summary: String?
  }

  public private(set) var evaluations: [Evaluation] = []
  public private(set) var failedPosition: Evaluation?
  private var frames: [Frame]
  public private(set) var state: WorkflowTypedState
  public private(set) var expiredDeliveries: Set<String> = []
  public private(set) var expiredActions: Set<String> = []
  public private(set) var currentStep: WorkflowStepDefinition?
  public var remainingSteps: [WorkflowStepDefinition] {
    frames.reversed().flatMap { frame in
      Array(frame.steps.dropFirst(frame.index)) + (frame.loop.map { [$0] } ?? [])
    }
  }
  public var isFinished: Bool { frames.isEmpty }
  public var iterationPath: [String] {
    frames.compactMap { frame in frame.loop.map { "\($0.id):\(frame.iteration)" } }
  }
  public var iteration: Int? { frames.last(where: { $0.loop != nil })?.iteration }

  public init(definition: WorkflowDefinition) throws {
    state = try WorkflowTypedState(declarations: definition.state)
    frames = [Frame(steps: definition.steps)]
  }

  public func values(over context: [String: WorkflowJSONValue]) -> [String: WorkflowJSONValue] {
    var result = context
    result["state"] = Self.object(state.values)
    for (group, expired) in [("deliveries", expiredDeliveries), ("actions", expiredActions)] {
      if case .object(var fields) = result[group] {
        for name in expired { fields.removeValue(forKey: name) }
        result[group] = .object(fields)
      }
    }
    return result
  }

  public mutating func next(values context: [String: WorkflowJSONValue], budget: Int = 64) throws -> Outcome {
    evaluations = []
    failedPosition = nil
    if let currentStep { return .step(currentStep) }
    for _ in 0..<max(1, budget) {
      guard let frame = frames.last else { return .finished }
      if frame.index >= frame.steps.count {
        failedPosition = frame.loop.map {
          Evaluation(stepID: $0.id, iteration: iteration, skipped: false, path: iterationPath)
        }
        try endFrame(context: context)
        failedPosition = nil
        continue
      }
      let step = frame.steps[frame.index]
      guard case .control(let control) = step.action else {
        currentStep = step
        return .step(step)
      }
      let position = if case .loop = control { 0 } else { iteration }
      let stepContext = Self.positioned(context, stepID: step.id, iteration: position)
      var positionRecord = Evaluation(stepID: step.id, iteration: iteration, skipped: false, path: iterationPath)
      positionRecord.title = step.title.flatMap {
        try? WorkflowExpression.renderText($0, values: values(over: stepContext))
      }
      failedPosition = positionRecord
      positionRecord.summary = try execute(control, step: step, context: stepContext)
      evaluations.append(positionRecord)
      failedPosition = nil
    }
    return frames.isEmpty ? .finished : .yielded
  }

  public mutating func complete() {
    guard let step = currentStep, !frames.isEmpty else { return }
    if case .action = step.action { expiredActions.remove(step.id) }
    if let output = step.deliveryName { expiredDeliveries.remove(output) }
    frames[frames.count - 1].index += 1
    currentStep = nil
  }

  private mutating func execute(
    _ control: WorkflowControlStep, step: WorkflowStepDefinition, context: [String: WorkflowJSONValue]
  ) throws -> String {
    switch control {
    case .set(let assignments):
      try state.assign(assignments, values: values(over: context))
      frames[frames.count - 1].index += 1
      return "Updated state: " + assignments.keys.sorted().joined(separator: ", ")
    case .conditional(let condition, let yes, let otherwise):
      let selected = try conditionValue(condition, context: context)
      let branch = selected ? yes : otherwise
      recordSkipped(selected ? otherwise : yes)
      frames[frames.count - 1].index += 1
      expire(step.action.children)
      frames.append(Frame(steps: branch))
      return "\(selected ? "Then" : "Else") branch selected\n\(condition) = \(selected)"
    case .loop(let condition, let maximum, let body):
      frames[frames.count - 1].index += 1
      expire(body)
      let entered = try conditionValue(condition, context: context)
      if entered {
        if let maximum, maximum <= 0 { throw WorkflowLoopLimit(stepID: step.id) }
        frames.append(Frame(steps: body, loop: step, iteration: 1))
      } else {
        recordSkipped(body)
      }
      return "\(entered ? "Entered loop" : "Loop not entered")\n\(condition) = \(entered)"
    case .breakLoop, .continueLoop:
      guard let loopIndex = frames.lastIndex(where: { $0.loop != nil }) else {
        throw WorkflowExpressionError.type("Loop control requires an enclosing loop.")
      }
      while frames.count - 1 > loopIndex { expire(frames.removeLast().steps) }
      if case .breakLoop = control {
        expire(frames.removeLast().steps)
        return "Exited the loop."
      } else {
        frames[loopIndex].index = frames[loopIndex].steps.count
        return "Continued to the next loop iteration."
      }
    }
  }

  private mutating func endFrame(context: [String: WorkflowJSONValue]) throws {
    guard let frame = frames.last else { return }
    if let loop = frame.loop, case .control(.loop(let condition, let maximum, _)) = loop.action {
      expire(frame.steps)
      let loopContext = Self.positioned(context, stepID: loop.id, iteration: frame.iteration)
      var evaluation = Evaluation(
        stepID: loop.id, iteration: frames.dropLast().last(where: { $0.loop != nil })?.iteration,
        skipped: false, path: Array(iterationPath.dropLast()))
      evaluation.title = loop.title.flatMap {
        try? WorkflowExpression.renderText($0, values: values(over: loopContext))
      }
      failedPosition = evaluation
      let matched = try conditionValue(condition, context: loopContext)
      evaluation.summary = "Loop condition \(matched ? "matched" : "ended the loop")\n\(condition) = \(matched)"
      evaluations.append(evaluation)
      if matched {
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
      evaluations.append(Evaluation(stepID: step.id, iteration: iteration, skipped: true, path: iterationPath))
      recordSkipped(step.action.children)
    }
  }

  private mutating func expire(_ steps: [WorkflowStepDefinition]) {
    for step in steps {
      if case .action = step.action { expiredActions.insert(step.id) }
      if let output = step.deliveryName { expiredDeliveries.insert(output) }
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
