// ProwlCLI/Commands/CloseCommand.swift

import ArgumentParser
import ProwlCLIShared

struct CloseCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "close",
    abstract: "Close a terminal pane or tab."
  )

  @Argument(help: "Pane/tab UUID or prefixed handle (pN or tN).")
  var target: String?

  @OptionGroup var selector: LifecycleSelectorOptions
  @OptionGroup var options: GlobalOptions

  @Flag(name: .long, help: "Close without prompting for protected panes.")
  var force = false

  mutating func run() throws {
    try CLIExecution.run(command: "close", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .close(CloseInput(selector: try selector.resolveTerminalTarget(positionalTarget: target), force: force))
      )
      try CLIRunner.execute(envelope)
    }
  }
}
