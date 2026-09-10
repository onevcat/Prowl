import Foundation

nonisolated enum ConsoleAgentPreset: String, Codable, CaseIterable, Identifiable {
  case codex, claude, custom

  var id: String { rawValue }
  var title: String {
    switch self {
    case .codex: "Codex"
    case .claude: "Claude"
    case .custom: "Default"
    }
  }
  var command: String {
    switch self {
    case .codex: "codex --yolo"
    case .claude: "claude --dangerously-skip-permissions"
    case .custom: ""
    }
  }
  var runtime: AgentProfileRuntime? {
    switch self {
    case .codex: .codex
    case .claude: .claude
    case .custom: nil
    }
  }

  func matching(command: String) -> Self {
    guard self != .custom, let executable = ShellWordSplitter.split(command).first,
      !executable.isEmpty
    else { return self }
    return executable == rawValue ? self : .custom
  }

  static func invocation(command: String, prompt: String) throws -> AgentInvocation {
    let words = ShellWordSplitter.split(command)
    guard let executable = words.first, !executable.isEmpty,
      !command.contains("\0"), !command.contains("\n"), !command.contains("\r")
    else { throw CommandError() }
    // Code security: user-authored argv is always rendered through AgentInvocation's quoting.
    return AgentInvocation(executable: executable, arguments: Array(words.dropFirst()) + [prompt])
  }

  func plan(profile: AgentProfile, invocation: AgentInvocation, prompt: String) throws
    -> AgentProfileLaunchPlan
  {
    var effective = profile
    effective.runtime = runtime ?? profile.runtime
    effective.model = nil
    effective.reasoningEffort = nil
    effective.executionMode = .standard
    effective.extraArguments = ""
    let base = try AgentProfileLaunchPlanner.plan(
      for: effective, intent: .prompt(prompt),
      homeBaseDirectory: SupacodePaths.agentProfileHomesDirectory)
    return AgentProfileLaunchPlan(
      profileID: base.profileID, profileName: base.profileName, runtime: base.runtime,
      invocation: invocation, commandEnvironmentTokens: base.commandEnvironmentTokens,
      placement: base.placement, splitDirection: base.splitDirection,
      surfaceEnvironment: base.surfaceEnvironment,
      profileEnvironmentOverrides: base.profileEnvironmentOverrides,
      dedicatedHome: base.dedicatedHome, sessionConfigRoot: base.sessionConfigRoot)
  }

  private struct CommandError: LocalizedError {
    var errorDescription: String? { "Enter a single-line executable and its arguments." }
  }
}
