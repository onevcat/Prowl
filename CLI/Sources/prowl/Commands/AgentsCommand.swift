// ProwlCLI/Commands/AgentsCommand.swift

import ArgumentParser
import ProwlCLIShared

struct AgentsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "agents",
    abstract: "List or report agent state.",
    subcommands: [
      AgentsReadCommand.self,
      AgentsSignalCommand.self,
      AgentsHookCommand.self,
      AgentsDispatchCommand.self,
      AgentsDispatchCompleteCommand.self,
      AgentsDispatchAbandonCommand.self,
      AgentsWaitCommand.self,
    ]
  )

  @OptionGroup var options: GlobalOptions

  mutating func run() throws {
    try CLIExecution.run(command: "agents", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .agents(AgentsInput())
      )
      try CLIRunner.execute(envelope)
    }
  }
}
