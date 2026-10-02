// ProwlCLI/Commands/PaneCommand.swift

import ArgumentParser
import ProwlCLIShared

struct PaneCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pane",
    abstract: "[Deprecated] Manage terminal panes. Use `prowl close`.",
    subcommands: [
      PaneCloseCommand.self,
    ]
  )
}

struct PaneCloseCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "close",
    abstract: "[Deprecated] Close a terminal pane. Use `prowl close <pane>`."
  )

  @OptionGroup var selector: SelectorOptions
  @OptionGroup var options: GlobalOptions

  @Flag(name: .long, help: "Close without prompting for protected panes.")
  var force = false

  mutating func run() throws {
    emitDeprecationWarning(command: "pane close", replacement: "close <pane>")
    try CLIExecution.run(command: "pane", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let resolvedSelector = try selector.resolve()
      guard !resolvedSelector.isNone else {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "pane close requires an explicit target selector."
        )
      }
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .pane(PaneInput(action: .close, selector: resolvedSelector, force: force))
      )
      try CLIRunner.execute(envelope)
    }
  }
}
