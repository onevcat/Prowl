import ArgumentParser
import ProwlCLIShared

/// One-release migration boundary for the removed hardcoded handoff protocol.
/// It deliberately never creates a command envelope or contacts the app.
struct HandoffCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "handoff",
    abstract: "Retired. Use `prowl workflow run prowl.handoff` instead."
  )

  @Argument(parsing: .captureForPassthrough) var legacyArguments: [String] = []

  mutating func run() throws {
    let output: OutputMode = legacyArguments.contains("--json") ? .json : .text
    try CLIExecution.run(
      command: "handoff", output: output, colorEnabled: !legacyArguments.contains("--no-color")
    ) {
      throw ExitError(code: CLIErrorCode.handoffRetired, message: Self.replacement)
    }
  }

  private static let replacement = """
    `prowl handoff` is retired and performs no action. To hand off to a receiver, run:
    prowl workflow run prowl.handoff --role receiver=<Profile>
    To save without launching a receiver, run:
    prowl workflow run prowl.handoff --input next=save
    Follow the returned self-initiated delivery instruction to submit the briefing.
    """
}
