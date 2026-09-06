import Foundation

nonisolated public indirect enum WorkflowControlStep: Equatable, Sendable {
  case set([String: String])
  case conditional(condition: String, then: [WorkflowStepDefinition], else: [WorkflowStepDefinition])
  case loop(condition: String, maximum: Int?, steps: [WorkflowStepDefinition])
  case breakLoop
  case continueLoop

  public var verb: String {
    switch self {
    case .set: "set"
    case .conditional: "if"
    case .loop: "while"
    case .breakLoop: "break"
    case .continueLoop: "continue"
    }
  }
}

extension WorkflowStepAction {
  public var children: [WorkflowStepDefinition] {
    switch self {
    case .control(.loop(_, _, let body)): body
    case .control(.conditional(_, let yes, let otherwise)): yes + otherwise
    default: []
    }
  }

  public var descendants: [WorkflowStepDefinition] {
    children.flatMap { [$0] + $0.action.descendants }
  }
}
