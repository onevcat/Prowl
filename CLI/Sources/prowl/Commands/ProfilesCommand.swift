import ArgumentParser
import ProwlCLIShared

struct ProfilesCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "profiles",
    abstract: "Inspect configured Agent Profiles.",
    subcommands: [ProfilesListCommand.self]
  )
}

struct ProfilesListCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List enabled and disabled Agent Profiles with runtime availability."
  )

  @OptionGroup var options: GlobalOptions

  mutating func run() throws {
    try CLIExecution.run(command: "profiles", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .profiles(ProfilesInput())
      )
      try CLIRunner.execute(envelope)
    }
  }
}
