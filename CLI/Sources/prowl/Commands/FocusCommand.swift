// ProwlCLI/Commands/FocusCommand.swift

import ArgumentParser
import ProwlCLIShared

struct FocusCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "focus",
    abstract: "Focus a worktree, tab, or pane and bring app to front."
  )

  @OptionGroup var selector: SelectorOptions
  @OptionGroup var options: GlobalOptions

  @Argument(help: "Target pane/tab UUID or worktree id/name/path (auto-resolved).")
  var target: String?

  mutating func run() throws {
    try CLIExecution.run(command: "focus", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let sel = try selector.resolve(positionalTarget: target)
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .focus(FocusInput(selector: sel))
      )
      try CLIRunner.execute(envelope)
    }
  }
}
