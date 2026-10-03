// ProwlCLI/Commands/SendCommand.swift

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ArgumentParser
import Foundation
import ProwlCLIShared

struct SendCommand: ParsableCommand {
  /// Check if stdin has readable data using poll(2) with zero timeout.
  private static func stdinHasData() -> Bool {
    var pfd = pollfd(fd: fileno(stdin), events: Int16(POLLIN), revents: 0)
    return poll(&pfd, 1, 0) > 0 && (pfd.revents & Int16(POLLIN)) != 0
  }

  static let configuration = CommandConfiguration(
    commandName: "send",
    abstract: "Send text input to a terminal pane.",
    discussion: """
      With one positional argument, it is treated as text sent to the current pane.
      With two positional arguments, the first is the target (auto-resolved) and
      the second is the text.
      """
  )

  @OptionGroup var selector: SelectorOptions
  @OptionGroup var options: GlobalOptions

  @Flag(name: .long, help: "Do not send trailing Enter after text.")
  var noEnter = false

  @Flag(name: .long, help: "Return immediately without waiting for command completion.")
  var noWait = false

  @Flag(name: .long, help: "Capture screen output produced by the command and include it in the response.")
  var capture = false

  @Option(name: .long, help: "Maximum seconds to wait for completion (1–300, default: 30).")
  var timeout: Int?

  @Argument(
    help: """
      Text to send, or target followed by text. \
      One argument: text sent to current pane. \
      Two arguments: first is target (auto-resolved), second is text.
      """
  )
  var args: [String] = []

  mutating func run() throws {
    try CLIExecution.run(command: "send", output: options.outputMode, colorEnabled: options.colorEnabled) {
      // Parse positional args: 0 = stdin, 1 = text, 2 = target + text
      let positionalTarget: String?
      let positionalText: String?
      switch args.count {
      case 0:
        positionalTarget = nil
        positionalText = nil
      case 1:
        positionalTarget = nil
        positionalText = args[0]
      case 2:
        positionalTarget = args[0]
        positionalText = args[1]
      default:
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "Expected at most 2 positional arguments (target and text), got \(args.count)."
        )
      }

      let sel = try selector.resolve(positionalTarget: positionalTarget)

      if let timeout, (timeout < 1 || timeout > 300) {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "Timeout must be between 1 and 300 seconds."
        )
      }

      if capture && noWait {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "--capture requires waiting for command completion. Remove --no-wait."
        )
      }

      if capture && noEnter {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "--capture requires a trailing Enter to run the command. Remove --no-enter."
        )
      }

      // Resolve input source: argv xor stdin
      let stdinIsPiped = isatty(fileno(stdin)) == 0 && Self.stdinHasData()
      let inputText: String
      let source: InputSource
      if let argText = positionalText {
        if stdinIsPiped {
          throw ExitError(
            code: CLIErrorCode.invalidArgument,
            message: "Cannot provide text as both argument and stdin."
          )
        }
        inputText = argText
        source = .argv
      } else if stdinIsPiped {
        guard let stdinData = try? FileHandle.standardInput.readToEnd(),
              let stdinText = String(data: stdinData, encoding: .utf8),
              !stdinText.isEmpty
        else {
          throw ExitError(
            code: CLIErrorCode.emptyInput,
            message: "No input provided via argument or stdin."
          )
        }
        inputText = stdinText
        source = .stdin
      } else {
        throw ExitError(
          code: CLIErrorCode.emptyInput,
          message: "No input provided. Pass text as argument or pipe via stdin."
        )
      }

      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .send(SendInput(
          selector: sel,
          text: inputText,
          trailingEnter: !noEnter,
          source: source,
          wait: !noWait,
          timeoutSeconds: timeout,
          captureOutput: capture
        ))
      )
      try CLIRunner.execute(envelope)
    }
  }
}
