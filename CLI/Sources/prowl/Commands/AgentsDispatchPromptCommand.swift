import ArgumentParser
import Foundation
import ProwlCLIShared

/// `prowl agents dispatch <pane> --prompt -`: assign a new task to an agent that already
/// runs in a pane and receive a pending dispatch receipt for it.
struct AgentsDispatchCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "dispatch",
    abstract: "Dispatch a new prompt into an existing idle agent pane and return its pending receipt."
  )

  @Argument(help: "Target agent pane handle (pN) or pane UUID from prowl agents.")
  var pane: String

  @Option(name: .long, help: "Prompt source; the only supported value is '-' for piped stdin.")
  var prompt: String

  @OptionGroup var options: GlobalOptions

  mutating func run() throws {
    try CLIExecution.run(command: "agents.dispatch", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .agentsDispatch(try makeInput())
      )
      try CLIRunner.execute(envelope)
    }
  }

  func validate() throws {
    guard Self.isExplicitPaneTarget(pane) else {
      throw ValidationError("agents dispatch requires a pane handle (pN) or pane UUID.")
    }
    guard prompt == "-" else {
      throw ValidationError("--prompt accepts only '-' to read the prompt from stdin.")
    }
  }

  func makeInput(
    stdinIsTerminal: Bool = isatty(fileno(stdin)) != 0,
    readStdin: () throws -> Data? = { try FileHandle.standardInput.readToEnd() }
  ) throws -> DispatchInput {
    guard !stdinIsTerminal else {
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "--prompt - requires piped stdin; it cannot read from an interactive terminal."
      )
    }
    guard let data = try? readStdin() else {
      throw ExitError(code: CLIErrorCode.emptyInput, message: "Failed to read the dispatch prompt from stdin.")
    }
    guard data.count <= DispatchInput.maximumPromptUTF8ByteCount else {
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "The dispatch prompt exceeds the 256 KiB UTF-8 limit."
      )
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw ExitError(code: CLIErrorCode.emptyInput, message: "Failed to read the dispatch prompt as UTF-8.")
    }
    // Heredocs end with a newline and Windows-authored files carry CRLF; neither is content.
    var prompt = text.replacing("\r\n", with: "\n")
    while prompt.hasSuffix("\n") { prompt.removeLast() }
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ExitError(code: CLIErrorCode.emptyInput, message: "The dispatch prompt is empty.")
    }
    let input = DispatchInput(pane: pane, prompt: prompt)
    if let message = input.validationErrorMessage {
      throw ExitError(code: CLIErrorCode.invalidArgument, message: message)
    }
    return input
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
