import ArgumentParser
import Foundation
import ProwlCLIShared

extension DispatchCompletionOutcome: ExpressibleByArgument {}
extension AgentWaitCondition: ExpressibleByArgument {}
extension AgentWaitMinimumConfidence: ExpressibleByArgument {}

struct AgentsDispatchCompleteCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "dispatch-complete",
    abstract: "Record the terminal outcome for this pane's current dispatch."
  )

  @Option(name: .long, help: "Terminal outcome: succeeded or failed.")
  var outcome: DispatchCompletionOutcome

  @Option(name: .long, help: "Required concise result summary (maximum 32768 UTF-8 bytes).")
  var summary: String

  @OptionGroup var options: GlobalOptions

  mutating func run() throws {
    try CLIExecution.run(
      command: "agents.dispatch-complete",
      output: options.outputMode,
      colorEnabled: options.colorEnabled
    ) {
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .agentsDispatchComplete(try makeInput())
      )
      try CLIRunner.execute(envelope)
    }
  }

  func validate() throws {
    let input = DispatchCompleteInput(dispatchID: nil, outcome: outcome, summary: summary)
    if let message = input.validationErrorMessage {
      throw ValidationError(message)
    }
  }

  /// The app resolves the receipt from the caller's process ancestry; a launch-scoped
  /// `PROWL_DISPATCH_ID` rides along as diagnostics only, so its absence is not an error.
  func makeInput(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> DispatchCompleteInput {
    let input = DispatchCompleteInput(
      dispatchID: environment[DispatchCompleteInput.environmentKey],
      outcome: outcome,
      summary: summary
    )
    if let message = input.validationErrorMessage {
      throw ExitError(code: CLIErrorCode.invalidArgument, message: message)
    }
    return input
  }
}

struct AgentsDispatchAbandonCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "dispatch-abandon",
    abstract: "Stop waiting for a pending dispatch without stopping its worker."
  )

  @Option(name: .customLong("dispatch"), help: "Opaque dispatch identifier.")
  var dispatchID: String

  @Option(name: .long, help: "Required abandonment reason (maximum 32768 UTF-8 bytes).")
  var reason: String

  @OptionGroup var options: GlobalOptions

  mutating func run() throws {
    try CLIExecution.run(
      command: "agents.dispatch-abandon",
      output: options.outputMode,
      colorEnabled: options.colorEnabled
    ) {
      let input = DispatchAbandonInput(dispatchID: dispatchID, reason: reason)
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .agentsDispatchAbandon(input)
      )
      try CLIRunner.execute(envelope)
    }
  }

  func validate() throws {
    let input = DispatchAbandonInput(dispatchID: dispatchID, reason: reason)
    if let message = input.validationErrorMessage {
      throw ValidationError(message)
    }
  }
}

struct AgentsWaitCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "wait",
    abstract: "Wait for an exact dispatch receipt or an observed pane condition."
  )

  @Argument(help: "Pane UUID or short handle for condition waits.")
  var pane: String?

  @Option(name: .customLong("dispatch"), help: "Opaque dispatch identifier for an exact receipt wait.")
  var dispatchID: String?

  @Option(name: .customLong("until"), help: "Condition: idle, blocked, changed, or exit.")
  var condition: AgentWaitCondition?

  @Option(name: .customLong("timeout"), help: "Wait timeout in seconds (1 through 600).")
  var timeoutSeconds = AgentWaitInput.defaultTimeoutSeconds

  @Option(
    name: .customLong("min-confidence"),
    help: "Minimum evidence confidence: auto, exact, high, or heuristic."
  )
  var minimumConfidence: AgentWaitMinimumConfidence?

  @Option(
    name: .customLong("include-screen"),
    help: "Capture this many stable detection-source lines after matching (1 through 200)."
  )
  var includeScreenLines: Int?

  @OptionGroup var options: GlobalOptions

  mutating func run() throws {
    try CLIExecution.run(command: "agents.wait", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .agentsWait(try makeInput())
      )
      try CLIRunner.execute(envelope)
    }
  }

  func validate() throws {
    _ = try makeInput(asValidationError: true)
  }

  func makeInput() throws -> AgentWaitInput {
    try makeInput(asValidationError: false)
  }

  private func makeInput(asValidationError: Bool) throws -> AgentWaitInput {
    func fail(_ message: String) throws -> Never {
      if asValidationError {
        throw ValidationError(message)
      }
      throw ExitError(code: CLIErrorCode.invalidArgument, message: message)
    }

    guard (1...AgentWaitInput.maximumTimeoutSeconds).contains(timeoutSeconds) else {
      try fail("--timeout must be between 1 and 600 seconds.")
    }
    if let includeScreenLines,
      !(1...AgentWaitInput.maximumScreenLines).contains(includeScreenLines)
    {
      try fail("--include-screen must be between 1 and 200 lines.")
    }

    if let dispatchID {
      guard pane == nil, condition == nil, minimumConfidence == nil else {
        try fail("--dispatch cannot be combined with a pane, --until, or --min-confidence.")
      }
      if let message = DispatchAbandonInput(dispatchID: dispatchID, reason: "validation").validationErrorMessage {
        try fail(message)
      }
      return AgentWaitInput(
        mode: .dispatch,
        dispatchID: dispatchID,
        timeoutSeconds: timeoutSeconds,
        includeScreenLines: includeScreenLines
      )
    }

    guard let pane, !pane.isEmpty, let condition else {
      try fail("A condition wait requires a pane and --until idle|blocked|changed|exit.")
    }
    return AgentWaitInput(
      mode: .condition,
      pane: pane,
      condition: condition,
      timeoutSeconds: timeoutSeconds,
      minimumConfidence: minimumConfidence ?? .auto,
      includeScreenLines: includeScreenLines
    )
  }
}
