// ProwlCLI/Commands/CreateCommand.swift

import ArgumentParser
import Foundation
import ProwlCLIShared

struct CreateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract: "Create a terminal resource.",
    subcommands: [
      CreateTabCommand.self,
      CreatePaneCommand.self,
    ]
  )

  static func validateProfileLaunchResponse(
    _ response: CommandResponse,
    requestedLaunch: CreateLaunchInput?
  ) throws {
    guard let requestedLaunch else { return }
    guard
      let data = response.data,
      let payload = try? data.decode(as: LifecycleCommandPayload.self),
      payload.launch != nil
    else {
      throw ExitError(
        code: CLIErrorCode.createFailed,
        message: "The running Prowl app did not honor the Profile launch. An ordinary shell may have been created; inspect prowl list and close it before retrying. Update or restart Prowl."
      )
    }
    guard requestedLaunch.prompt == nil || payload.dispatch != nil else {
      throw ExitError(
        code: CLIErrorCode.createFailed,
        message: "The running Prowl app did not create a dispatch receipt for the prompted launch. Inspect prowl list and close the created resource before retrying. Update or restart Prowl."
      )
    }
  }
}

struct CreateLaunchOptions: ParsableArguments {
  @Option(name: .long, help: "Agent Profile name or UUID to launch in the new resource.")
  var profile: String?

  @Option(name: .long, help: "Kickoff prompt source; the only supported value is '-' for stdin.")
  var prompt: String?

  @Flag(name: .long, help: "Create without changing selection or focus; split panes require a Profile.")
  var background = false

  func resolve(
    allowsBackgroundShell: Bool = false,
    stdinIsTerminal: Bool = isatty(fileno(stdin)) != 0,
    readStdin: () throws -> Data? = { try FileHandle.standardInput.readToEnd() }
  ) throws -> (launch: CreateLaunchInput?, background: Bool) {
    guard let profile else {
      if prompt != nil || (background && !allowsBackgroundShell) {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "--prompt and --background require --profile."
        )
      }
      return (nil, background)
    }
    guard !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ExitError(code: CLIErrorCode.invalidArgument, message: "--profile must not be empty.")
    }
    guard let prompt else {
      return (CreateLaunchInput(profile: profile), background)
    }
    guard prompt == "-" else {
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "--prompt accepts only '-' to read the kickoff prompt from stdin."
      )
    }
    guard !stdinIsTerminal else {
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "--prompt - requires piped stdin; it cannot read from an interactive terminal."
      )
    }
    guard let data = try? readStdin() else {
      throw ExitError(code: CLIErrorCode.emptyInput, message: "Failed to read the kickoff prompt from stdin.")
    }
    guard data.count <= CreateLaunchInput.maximumPromptUTF8ByteCount else {
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "The kickoff prompt exceeds the 256 KiB UTF-8 limit."
      )
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw ExitError(code: CLIErrorCode.emptyInput, message: "Failed to read the kickoff prompt as UTF-8.")
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ExitError(code: CLIErrorCode.emptyInput, message: "The kickoff prompt is empty.")
    }
    return (CreateLaunchInput(profile: profile, prompt: text), background)
  }
}

struct CreateTabCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tab",
    abstract: "Create a new terminal tab."
  )

  @Argument(help: "Worktree id, name, or path.")
  var worktree: String?

  @OptionGroup var selector: LifecycleSelectorOptions
  @OptionGroup var launchOptions: CreateLaunchOptions
  @OptionGroup var options: GlobalOptions

  @Option(name: .long, help: "Working directory for the new tab.")
  var path: String?

  mutating func run() throws {
    try CLIExecution.run(command: "create", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let input = try makeInput()
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .create(input)
      )
      try CLIRunner.execute(envelope) { response in
        try CreateCommand.validateProfileLaunchResponse(response, requestedLaunch: input.launch)
      }
    }
  }

  func makeInput() throws -> CreateInput {
    let resolvedLaunch = try launchOptions.resolve(allowsBackgroundShell: true)
    return CreateInput(
      resource: .tab,
      selector: try selector.resolveWorktree(positionalTarget: worktree),
      path: normalizedPath(),
      launch: resolvedLaunch.launch,
      background: resolvedLaunch.background
    )
  }

  private func normalizedPath() -> String? {
    guard let path else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
      .standardizedFileURL
      .path(percentEncoded: false)
      .trimmingTrailingSlash()
  }
}

struct CreatePaneCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pane",
    abstract: "Create a split pane beside an existing pane."
  )

  enum Direction: String, ExpressibleByArgument {
    case right
    case left
    case up
    case down

    var value: CreatePaneDirection {
      switch self {
      case .right: .right
      case .left: .left
      case .up: .upward
      case .down: .down
      }
    }
  }

  @Argument(help: "Anchor pane UUID or short handle (for example, p3).")
  var anchor: String?

  @OptionGroup var selector: LifecycleSelectorOptions
  @OptionGroup var launchOptions: CreateLaunchOptions
  @OptionGroup var options: GlobalOptions

  @Option(name: .long, help: "Split direction: right, left, up, or down.")
  var direction: Direction

  mutating func run() throws {
    try CLIExecution.run(command: "create", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let input = try makeInput()
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .create(input)
      )
      try CLIRunner.execute(envelope) { response in
        try CreateCommand.validateProfileLaunchResponse(response, requestedLaunch: input.launch)
      }
    }
  }

  func makeInput() throws -> CreateInput {
    let resolvedLaunch = try launchOptions.resolve()
    return CreateInput(
      resource: .pane,
      selector: try selector.resolvePane(positionalTarget: anchor),
      direction: direction.value,
      launch: resolvedLaunch.launch,
      background: resolvedLaunch.background
    )
  }
}

private extension String {
  func trimmingTrailingSlash() -> String {
    var value = self
    while value.count > 1, value.hasSuffix("/") {
      value.removeLast()
    }
    return value
  }
}
