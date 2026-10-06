import Foundation

nonisolated struct DevinRuntimeAdapter: AgentRuntimeAdapter {
  let runtime: AgentProfileRuntime = .devin
  let displayName = "Devin"
  let supportsModelSelection = true
  let executionModeOptions = AgentExecutionMode.allCases

  func observe(arguments: [String]) -> AgentLaunchObservation {
    let options = Array(arguments.prefix { $0 != "--" })
    let mode = options.optionValue(long: "--permission-mode")
    let executionMode: AgentExecutionMode?
    switch mode {
    case "auto", "normal": executionMode = .standard
    case "dangerous", "yolo", "bypass": executionMode = .unrestricted
    default: executionMode = nil
    }
    return AgentLaunchObservation(
      model: options.optionValue(long: "--model"), executionMode: executionMode)
  }

  func makeStartInvocation(_ request: AgentStartRequest) throws -> AgentInvocation {
    var generated: [String] = []
    if let model = request.configuration.model { generated += ["--model", model] }
    generated += [
      "--permission-mode",
      request.configuration.executionMode == .unrestricted ? "dangerous" : "auto",
    ]
    let options = finalizedOptions(generated, request: request)
    // Bare positional arguments open Desktop. `--` also protects prompts that start with a dash.
    return switch request.intent {
    case .interactive: AgentInvocation(executable: "devin", arguments: options)
    case .prompt(let prompt):
      AgentInvocation(executable: "devin", arguments: options + ["--", prompt])
    case .headless(let prompt):
      AgentInvocation(executable: "devin", arguments: options + ["--print", "--", prompt])
    }
  }
}
