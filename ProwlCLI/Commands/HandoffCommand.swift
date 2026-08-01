// ProwlCLI/Commands/HandoffCommand.swift

import ArgumentParser
import Foundation
import ProwlCLIShared

struct HandoffCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "handoff",
    abstract: "Hand a task off between agents: archive, brief, and launch the receiver.",
    subcommands: [
      HandoffSaveCommand.self,
      HandoffToCommand.self,
    ]
  )
}

/// Shared briefing options. `--brief <text|->` supplies the agent-authored
/// briefing inline (`-` reads stdin, the standard heredoc posture for a
/// self-handoff); `--no-brief` is the explicit context-only escape.
struct HandoffBriefOptions: ParsableArguments {
  @Option(
    name: .long,
    help: "Inline agent-authored briefing; pass '-' to read it from stdin (heredoc)."
  )
  var brief: String?

  @Flag(name: .customLong("no-brief"), help: "Context-only: skip the briefing entirely.")
  var noBrief = false

  /// Resolve to the wire shape, reading stdin for the `-` sentinel.
  func resolve() throws -> (brief: String?, contextOnly: Bool) {
    if noBrief, brief != nil {
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "--brief and --no-brief are mutually exclusive."
      )
    }
    guard var text = brief else { return (nil, noBrief) }
    if text == "-" {
      guard
        let data = try? FileHandle.standardInput.readToEnd(),
        let stdinText = String(data: data, encoding: .utf8)
      else {
        throw ExitError(code: CLIErrorCode.emptyInput, message: "Failed to read the briefing from stdin.")
      }
      text = stdinText
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ExitError(code: CLIErrorCode.emptyInput, message: "The briefing is empty.")
    }
    return (text, false)
  }
}

/// The HUD prefixes its injected shell command with a UUID environment value.
/// Normal interactive CLI use never sets it.
enum HandoffRequestContext {
  static var currentID: UUID? {
    requestID(in: ProcessInfo.processInfo.environment)
  }

  static func requestID(in environment: [String: String]) -> UUID? {
    guard let rawID = environment[HandoffInput.requestIDEnvironmentKey] else { return nil }
    return UUID(uuidString: rawID)
  }
}


struct HandoffSaveCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "save",
    abstract: "Checkpoint: install a fresh briefing and refresh generated context, without launching."
  )

  @OptionGroup var selector: SelectorOptions
  @OptionGroup var briefOptions: HandoffBriefOptions
  @OptionGroup var options: GlobalOptions

  @Argument(help: "Source pane/tab UUID or worktree id/name/path (defaults to the calling pane).")
  var target: String?

  @Option(name: .long, help: "Optional note appended to the handoff log.")
  var note: String?

  mutating func run() throws {
    try CLIExecution.run(command: "handoff", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let resolvedBrief = try briefOptions.resolve()
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .handoff(
          HandoffInput(
            action: .save,
            selector: try selector.resolve(positionalTarget: target),
            note: note,
            brief: resolvedBrief.brief,
            contextOnly: resolvedBrief.contextOnly,
            requestID: HandoffRequestContext.currentID

          )
        )
      )
      try CLIRunner.execute(envelope)
    }
  }
}

struct HandoffToCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "to",
    abstract: "Archive the outgoing state, install the briefing, and launch the receiving agent."
  )

  @Argument(
    help:
      "The agent to hand off to. Required unless --agent-profile-id is provided. Launch supported: \(HandoffAgentSupport.launchableAgentsDescription); use --no-launch for other detected agents."
  )
  var agent: String?

  @Argument(help: "Source pane/tab UUID or worktree id/name/path (defaults to the calling pane).")
  var target: String?

  @OptionGroup var selector: SelectorOptions
  @OptionGroup var briefOptions: HandoffBriefOptions
  @OptionGroup var options: GlobalOptions

  @Option(name: .long, help: "Optional note appended to the handoff log.")
  var note: String?

  @Option(
    name: .customLong("agent-profile-id"),
    help: "Receiving Prowl Agent Profile UUID. Cannot be combined with the agent argument."
  )
  var agentProfileID: String?

  @Flag(name: .customLong("no-launch"), help: "Archive + save only; do not launch the receiving agent.")
  var noLaunch = false

  struct ReceivingTarget: Equatable {
    let agent: String?
    let profileID: UUID?
  }

  func resolveReceivingTarget() throws -> ReceivingTarget {
    switch (agent, agentProfileID) {
    case (nil, nil):
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "handoff to requires exactly one receiver: an agent argument or --agent-profile-id <uuid>."
      )
    case (.some, .some):
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message:
          "handoff to with --agent-profile-id does not accept positional arguments; select the source with --pane, --tab, or --worktree."
      )
    case (nil, .some(let rawProfileID)):
      guard let profileID = UUID(uuidString: rawProfileID) else {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "--agent-profile-id requires a valid UUID."
        )
      }
      return ReceivingTarget(agent: nil, profileID: profileID)
    case (.some(let rawAgent), nil):
      guard let normalizedAgent = HandoffAgentSupport.normalize(rawAgent.lowercased()) else {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "handoff to requires an agent of: \(HandoffAgentSupport.supportedAgentsDescription)."
        )
      }
      if !noLaunch, !HandoffAgentSupport.canLaunch(normalizedAgent) {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message:
            "handoff can only launch: \(HandoffAgentSupport.launchableAgentsDescription). Use --no-launch for other agents."
        )
      }
      return ReceivingTarget(agent: normalizedAgent, profileID: nil)
    }
  }

  mutating func run() throws {
    try CLIExecution.run(command: "handoff", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let receivingTarget = try resolveReceivingTarget()
      let resolvedBrief = try briefOptions.resolve()
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .handoff(
          HandoffInput(
            action: .toAgent,
            selector: try selector.resolve(positionalTarget: target),
            toAgent: receivingTarget.agent,
            toProfileID: receivingTarget.profileID,
            note: note,
            launch: !noLaunch,
            brief: resolvedBrief.brief,
            contextOnly: resolvedBrief.contextOnly,
            requestID: HandoffRequestContext.currentID
          )
        )
      )
      try CLIRunner.execute(envelope)
    }
  }
}
