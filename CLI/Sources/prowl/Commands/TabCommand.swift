// ProwlCLI/Commands/TabCommand.swift

import ArgumentParser
import Foundation
import ProwlCLIShared

struct TabCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tab",
    abstract: "[Deprecated] Create or close terminal tabs. Use `prowl create tab` or `prowl close`.",
    subcommands: [
      TabCreateCommand.self,
      TabCloseCommand.self,
    ]
  )
}

struct TabCreateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract: "[Deprecated] Create a new terminal tab. Use `prowl create tab`."
  )

  @OptionGroup var selector: SelectorOptions
  @OptionGroup var options: GlobalOptions

  @Option(name: .long, help: "Working directory for the new tab.")
  var path: String?

  mutating func run() throws {
    emitDeprecationWarning(command: "tab create", replacement: "create tab <worktree>")
    try CLIExecution.run(command: "tab", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .tab(TabInput(action: .create, selector: try selector.resolve(), path: normalizedPath()))
      )
      try CLIRunner.execute(envelope)
    }
  }

  private func normalizedPath() -> String? {
    guard let path else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
      .standardizedFileURL
      .path(percentEncoded: false)
      .trimmingTrailingSlash()
  }
}

struct TabCloseCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "close",
    abstract: "[Deprecated] Close a terminal tab. Use `prowl close <tab>`."
  )

  @OptionGroup var selector: SelectorOptions
  @OptionGroup var options: GlobalOptions

  @Flag(name: .long, help: "Close without prompting for protected panes.")
  var force = false

  mutating func run() throws {
    emitDeprecationWarning(command: "tab close", replacement: "close <tab>")
    try CLIExecution.run(command: "tab", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let resolvedSelector = try selector.resolve()
      guard !resolvedSelector.isNone else {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "tab close requires an explicit target selector."
        )
      }
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .tab(TabInput(action: .close, selector: resolvedSelector, force: force))
      )
      try CLIRunner.execute(envelope)
    }
  }
}

extension String {
  fileprivate func trimmingTrailingSlash() -> String {
    var value = self
    while value.count > 1, value.hasSuffix("/") {
      value.removeLast()
    }
    return value
  }
}
