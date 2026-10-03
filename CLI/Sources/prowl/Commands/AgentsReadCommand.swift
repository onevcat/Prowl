import ArgumentParser
import Foundation
import ProwlCLIShared

struct AgentsReadCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "read",
    abstract: "Read an immediate semantic snapshot of a Codex or Claude Code agent."
  )

  @Argument(help: "Target agent pane handle (pN) or pane UUID from prowl agents.")
  var pane: String

  @Option(
    name: .long,
    help: "Maximum result size in bytes (1–4194304, default: 1048576)."
  )
  var maxBytes = AgentReadInput.defaultMaxBytes

  @Flag(name: .long, help: "Write only a complete trusted result, with no snapshot header.")
  var resultOnly = false

  @OptionGroup var options: GlobalOptions

  mutating func run() throws {
    try CLIExecution.run(command: "agents.read", output: options.outputMode, colorEnabled: options.colorEnabled) {
      try validateOutputMode()
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .agentsRead(AgentReadInput(pane: pane, maxBytes: maxBytes, resultOnly: resultOnly))
      )
      try CLIRunner.execute(envelope)
    }
  }

  func validate() throws {
    guard Self.isExplicitPaneTarget(pane) else {
      throw ValidationError("agents read requires a pane handle (pN) or pane UUID.")
    }
    guard (1...AgentReadInput.maximumMaxBytes).contains(maxBytes) else {
      throw ValidationError("--max-bytes must be between 1 and \(AgentReadInput.maximumMaxBytes).")
    }
  }

  func validateOutputMode() throws {
    guard !(resultOnly && options.json) else {
      throw ExitError(code: CLIErrorCode.invalidArgument, message: "--result-only cannot be combined with --json.")
    }
  }

  private static func isExplicitPaneTarget(_ value: String) -> Bool {
    if UUID(uuidString: value) != nil { return true }
    let normalized = value.lowercased()
    guard normalized.hasPrefix("p") else { return false }
    let digits = normalized.dropFirst()
    return !digits.isEmpty
      && digits.allSatisfy { $0.isASCII && $0.isNumber }
      && Int(digits).map({ $0 > 0 }) == true
  }
}
