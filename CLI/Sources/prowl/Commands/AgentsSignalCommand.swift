import ArgumentParser
import Foundation
import ProwlCLIShared

extension AgentSignalEvent: ExpressibleByArgument {}

struct AgentsSignalCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "signal",
    abstract: "Report an event for the agent in the caller's Prowl pane."
  )

  @Argument(help: "Event: turn-ended, needs-input, session-start, session-end, or progress.")
  var event: AgentSignalEvent

  @Option(name: .long, help: "Progress from 0 through 100; omit for indeterminate progress.")
  var progress: Int?

  @Option(name: .long, help: "Claimed producer origin metadata; does not upgrade trust.")
  var origin: String?

  @Option(name: .customLong("session"), help: "Opaque agent session identifier.")
  var sessionID: String?

  @Option(
    name: .long,
    help:
      "Short result or reason returned with the signal (maximum \(AgentSignalInput.maximumDetailBytes) UTF-8 bytes)."
  )
  var detail: String?

  @OptionGroup var options: GlobalOptions

  mutating func run() throws {
    try CLIExecution.run(command: "agents.signal", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .agentsSignal(
          AgentSignalInput(
            event: event,
            progress: progress,
            origin: origin,
            sessionID: sessionID,
            detail: detail
          ))
      )
      try CLIRunner.execute(envelope)
    }
  }

  func validate() throws {
    let input = AgentSignalInput(
      event: event,
      progress: progress,
      origin: origin,
      sessionID: sessionID,
      detail: detail
    )
    if let message = input.validationErrorMessage {
      throw ValidationError(message)
    }
  }
}
