// ProwlCLI/Commands/KeyCommand.swift

import ArgumentParser
import Foundation
import ProwlCLIShared

struct KeyCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "key",
    abstract: "Send a keyboard shortcut or special key to a terminal pane.",
    discussion: """
      With one positional argument, the key is sent to the current pane.
      With two positional arguments, the first is the target (auto-resolved) and
      the second is the key token.

      Printable punctuation currently follows ANSI-style key token semantics.
      For shifted symbols, prefer modifier combos such as shift-1 or shift-left-bracket.
      """
  )

  @OptionGroup var selector: SelectorOptions
  @OptionGroup var options: GlobalOptions

  @Option(name: .long, help: "Number of times to repeat the key (1-100).")
  var `repeat`: Int = 1

  @Argument(
    help: """
      Key token, or target followed by key token. \
      One argument: key token sent to current pane. \
      Two arguments: first is target (auto-resolved), second is key token.
      """
  )
  var args: [String] = []

  mutating func run() throws {
    try CLIExecution.run(command: "key", output: options.outputMode, colorEnabled: options.colorEnabled) {
      // Parse positional args: 1 = token, 2 = target + token
      let positionalTarget: String?
      let rawToken: String
      switch args.count {
      case 1:
        positionalTarget = nil
        rawToken = args[0].trimmingCharacters(in: .whitespaces)
      case 2:
        positionalTarget = args[0]
        rawToken = args[1].trimmingCharacters(in: .whitespaces)
      default:
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "Expected 1 or 2 positional arguments (optional target and key token), got \(args.count)."
        )
      }

      let sel = try selector.resolve(positionalTarget: positionalTarget)

      guard (1...100).contains(self.repeat) else {
        throw ExitError(
          code: CLIErrorCode.invalidRepeat,
          message: "Repeat count must be between 1 and 100, got \(self.repeat)."
        )
      }

      guard let normalized = KeyTokens.normalize(rawToken) else {
        throw ExitError(
          code: CLIErrorCode.unsupportedKey,
          message: "The key token '\(rawToken.lowercased())' is not supported."
        )
      }

      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .key(KeyInput(
          selector: sel,
          rawToken: rawToken,
          token: normalized,
          repeatCount: self.repeat
        ))
      )
      try CLIRunner.execute(envelope)
    }
  }
}
