import Foundation
import ProwlCLIShared

nonisolated struct AgentSignalHookCapability: Equatable, Sendable {
  let runtime: AgentNativeHookRuntime
  let nativeEvents: [String: AgentSignalEvent]
  let coveredEvents: [AgentSignalEvent]

  init(runtime: AgentNativeHookRuntime, nativeEvents: [String: AgentSignalEvent]) {
    self.runtime = runtime
    self.nativeEvents = nativeEvents
    self.coveredEvents = Array(Set(nativeEvents.values)).sorted { $0.rawValue < $1.rawValue }
  }
}

/// Interactive and headless launch behavior for one supported runtime.
/// Handoff briefing is authored by the live source agent and does not resume
/// native sessions through this adapter boundary (docs-ai 055).
nonisolated protocol AgentRuntimeAdapter: Sendable {
  var runtime: AgentProfileRuntime { get }
  var displayName: String { get }
  var supportsModelSelection: Bool { get }
  var supportsReasoningEffort: Bool { get }
  /// Empty when the runtime cannot represent both persisted modes honestly.
  /// Adapters exposing the picker must render every listed mode, including
  /// inverse guarded flags for CLIs whose default is auto-approved.
  var executionModeOptions: [AgentExecutionMode] { get }
  var accountIsolation: AgentProfileHomeRelocation? { get }
  var signalHooks: AgentSignalHookCapability? { get }
  var reasoningEffortSuggestions: [String] { get }
  var modelSuggestions: [String] { get }

  func observe(arguments: [String]) -> AgentLaunchObservation
  func makeStartInvocation(_ request: AgentStartRequest) throws -> AgentInvocation
}

nonisolated extension AgentRuntimeAdapter {
  var supportsAccountIsolation: Bool { accountIsolation != nil }
  var accountHomeEnvironmentVariable: String? { accountIsolation?.environmentVariable }
  var supportsModelSelection: Bool { false }
  var supportsReasoningEffort: Bool { false }
  var executionModeOptions: [AgentExecutionMode] { [] }
  var accountIsolation: AgentProfileHomeRelocation? { nil }
  var signalHooks: AgentSignalHookCapability? { nil }
  var reasoningEffortSuggestions: [String] { [] }
  var modelSuggestions: [String] { [] }

  /// User arguments remain last-wins for ordinary options. A managed home is
  /// appended after them because account binding is an identity invariant:
  /// extra arguments must not silently redirect state outside the UUID home.
  func finalizedOptions(_ generated: [String], request: AgentStartRequest) -> [String] {
    var options = generated + request.configuration.extraArguments
    if let home = request.dedicatedHome, let accountIsolation {
      options += accountIsolation.arguments(for: home)
    }
    return options
  }
}

/// One path-valued CLI option in a managed-home relocation contract.
nonisolated struct AgentProfileHomePathArgument: Equatable, Sendable {
  let option: String
  /// Empty means the managed home itself; otherwise a child path.
  let relativePath: String
}

/// Verified full-state relocation for a runtime. Environment and CLI-argument
/// mechanisms share one model so the planner, editor, cleanup, and session
/// resolver agree on the same managed root (docs-ai 055).
nonisolated struct AgentProfileHomeRelocation: Equatable, Sendable {
  let environmentVariable: String?
  let pathArguments: [AgentProfileHomePathArgument]
  let sessionRootRelativePath: String
  let reservedEnvironmentVariables: Set<String>

  init(
    environmentVariable: String? = nil,
    pathArguments: [AgentProfileHomePathArgument] = [],
    sessionRootRelativePath: String = "",
    reservedEnvironmentVariables: Set<String> = []
  ) {
    self.environmentVariable = environmentVariable
    self.pathArguments = pathArguments
    self.sessionRootRelativePath = sessionRootRelativePath
    self.reservedEnvironmentVariables = reservedEnvironmentVariables.union(
      environmentVariable.map { [$0] } ?? []
    )
  }

  func arguments(for home: URL) -> [String] {
    pathArguments.flatMap { argument in
      let url =
        argument.relativePath.isEmpty
        ? home
        : home.appending(path: argument.relativePath, directoryHint: .isDirectory)
      return [argument.option, AgentProfileLaunchPlanner.pathString(url)]
    }
  }

  func sessionConfigRoot(for home: URL) -> URL {
    guard !sessionRootRelativePath.isEmpty else { return home }
    return home.appending(path: sessionRootRelativePath, directoryHint: .isDirectory)
  }
}

nonisolated enum AgentExecutionMode: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
  case standard
  case unrestricted

  var id: String { rawValue }

  var title: String {
    switch self {
    case .standard: "Standard"
    case .unrestricted: "Unrestricted"
    }
  }
}

/// How an agent process should begin. An empty prompt sentinel is forbidden by
/// construction: interactive-with-no-prompt and prompted starts are distinct
/// CLI semantics (docs-ai 053).
nonisolated enum AgentStartIntent: Equatable, Sendable {
  case interactive
  case prompt(String)
  case headless(String)

  var promptText: String? {
    switch self {
    case .interactive: nil
    case .prompt(let prompt), .headless(let prompt): prompt
    }
  }
}

nonisolated struct AgentLaunchConfiguration: Codable, Equatable, Sendable {
  var model: String?
  var executionMode: AgentExecutionMode
  var reasoningEffort: String?
  /// Literal argv tokens appended after adapter-generated options (last-wins)
  /// and before managed-home arguments and any positional prompt.
  var extraArguments: [String]

  init(
    model: String? = nil,
    executionMode: AgentExecutionMode = .standard,
    reasoningEffort: String? = nil,
    extraArguments: [String] = []
  ) {
    self.model = model
    self.executionMode = executionMode
    self.reasoningEffort = reasoningEffort
    self.extraArguments = extraArguments
  }

  private enum CodingKeys: String, CodingKey {
    case model, executionMode, reasoningEffort, extraArguments
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    executionMode =
      try container.decodeIfPresent(AgentExecutionMode.self, forKey: .executionMode) ?? .standard
    reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
    extraArguments = try container.decodeIfPresent([String].self, forKey: .extraArguments) ?? []
  }
}

/// Options observed from a live agent process. Nil denotes an unknown effective
/// setting, never an inferred safe default from the absence of an argv flag.
nonisolated struct AgentLaunchObservation: Equatable, Sendable {
  let model: String?
  let executionMode: AgentExecutionMode?

  init(model: String? = nil, executionMode: AgentExecutionMode? = nil) {
    self.model = model
    self.executionMode = executionMode
  }
}

nonisolated struct AgentStartRequest: Equatable, Sendable {
  let runtime: AgentProfileRuntime
  let intent: AgentStartIntent
  let configuration: AgentLaunchConfiguration
  /// Set only by Agent Profile planning. Handoff and ordinary starts are pure
  /// invocations and therefore leave this nil.
  let dedicatedHome: URL?

  var agent: DetectedAgent { runtime.agent }

  init(
    runtime: AgentProfileRuntime,
    intent: AgentStartIntent,
    configuration: AgentLaunchConfiguration = .init(),
    dedicatedHome: URL? = nil
  ) {
    self.runtime = runtime
    self.intent = intent
    self.configuration = configuration
    self.dedicatedHome = dedicatedHome
  }

  init(
    agent: DetectedAgent,
    intent: AgentStartIntent,
    configuration: AgentLaunchConfiguration = .init()
  ) {
    self.init(runtime: AgentProfileRuntime(agent: agent), intent: intent, configuration: configuration)
  }
}

nonisolated struct AgentInvocation: Equatable, Sendable {
  let executable: String
  let arguments: [String]

  init(executable: String, arguments: [String]) {
    self.executable = executable
    self.arguments = arguments
  }

  var terminalInput: String {
    terminalInput(replacingArgumentsWithEnvironmentVariables: [:])
  }

  /// Profile plans can carry arbitrary argv values through the surface
  /// environment instead of typing them into a canonical PTY. The logical
  /// invocation retains the real values while shell rendering substitutes
  /// quoted variable references at the declared indexes.
  func terminalInput(
    replacingArgumentsWithEnvironmentVariables replacements: [Int: String]
  ) -> String {
    var tokens = arguments.map(Self.shellQuote)
    for (index, variable) in replacements where tokens.indices.contains(index) {
      tokens[index] = "\"$\(variable)\""
    }
    return ([Self.shellQuote(executable)] + tokens).joined(separator: " ")
  }

  func terminalInput(replacingFinalArgumentWithEnvironmentVariable variable: String?) -> String {
    guard let variable, !arguments.isEmpty else { return terminalInput }
    return terminalInput(
      replacingArgumentsWithEnvironmentVariables: [arguments.index(before: arguments.endIndex): variable]
    )
  }

  static func shellQuote(_ argument: String) -> String {
    "'" + argument.replacing("'", with: "'\"'\"'") + "'"
  }
}

nonisolated enum AgentRuntimeError: Error, Equatable, Sendable {
  case unsupportedAgent(DetectedAgent)
  case unsupportedStartIntent(AgentProfileRuntime, AgentStartIntent)
}

nonisolated enum AgentRuntimeAdapterRegistry {
  static func profileAdapter(for runtime: AgentProfileRuntime) -> (any AgentRuntimeAdapter)? {
    switch runtime {
    case .claude: ClaudeCodeRuntimeAdapter()
    case .codex: CodexRuntimeAdapter()
    case .gemini: GeminiRuntimeAdapter()
    case .cursor: CursorRuntimeAdapter()
    case .cline: ClineRuntimeAdapter()
    case .opencode: OpenCodeRuntimeAdapter()
    case .copilot: CopilotRuntimeAdapter()
    case .kimi: KimiRuntimeAdapter()
    case .droid: DroidRuntimeAdapter()
    case .amp: AmpRuntimeAdapter()
    case .qoder: QoderRuntimeAdapter()
    case .qwen: QwenRuntimeAdapter()
    case .grok: GrokRuntimeAdapter()
    case .pi: PiRuntimeAdapter()
    case .omp: OMPRuntimeAdapter()
    }
  }

  /// Canonical launch adapter for one detected runtime.
  static func adapter(for agent: DetectedAgent) -> (any AgentRuntimeAdapter)? {
    profileAdapter(for: AgentProfileRuntime(agent: agent))
  }

  static var launchableAgents: [DetectedAgent] {
    DetectedAgent.allCases.filter { adapter(for: $0) != nil }
  }

  static func displayName(for runtime: AgentProfileRuntime) -> String {
    profileAdapter(for: runtime)?.displayName ?? runtime.rawValue
  }

  static func displayName(for agent: DetectedAgent) -> String {
    adapter(for: agent)?.displayName ?? agent.displayName
  }

  static func canStart(_ agent: DetectedAgent) -> Bool {
    adapter(for: agent) != nil
  }

  static func observe(runtime: AgentProfileRuntime, arguments: [String]) -> AgentLaunchObservation {
    profileAdapter(for: runtime)?.observe(arguments: arguments) ?? .init()
  }

  static func observe(agent: DetectedAgent, arguments: [String]) -> AgentLaunchObservation {
    return adapter(for: agent)?.observe(arguments: arguments) ?? .init()
  }

  static func inheritedConfiguration(
    from sourceAgent: DetectedAgent,
    observation: AgentLaunchObservation?,
    to destinationAgent: DetectedAgent
  ) -> AgentLaunchConfiguration {
    AgentLaunchConfiguration(
      model: sourceAgent == destinationAgent ? observation?.model : nil,
      executionMode: observation?.executionMode ?? .standard
    )
  }

  static func makeStartInvocation(_ request: AgentStartRequest) throws -> AgentInvocation {
    guard let adapter = profileAdapter(for: request.runtime) else {
      throw AgentRuntimeError.unsupportedAgent(request.agent)
    }
    return try adapter.makeStartInvocation(request)
  }

}

// MARK: - Launch adapters

nonisolated private struct CodexRuntimeAdapter: AgentRuntimeAdapter {
  let runtime: AgentProfileRuntime = .codex
  let displayName = "Codex"
  let supportsModelSelection = true
  let supportsReasoningEffort = true
  let executionModeOptions = AgentExecutionMode.allCases
  let accountIsolation: AgentProfileHomeRelocation? = AgentProfileHomeRelocation(environmentVariable: "CODEX_HOME")
  let signalHooks: AgentSignalHookCapability? = AgentSignalHookCapability(
    runtime: .codex,
    nativeEvents: AgentNativeHookDecoder.nativeEvents(for: .codex)
  )
  let reasoningEffortSuggestions = ["low", "medium", "high", "xhigh", "max"]
  let modelSuggestions = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]

  func observe(arguments: [String]) -> AgentLaunchObservation {
    AgentLaunchObservation(
      model: arguments.optionValue(long: "--model", short: "-m"),
      executionMode: arguments.containsAny("--dangerously-bypass-approvals-and-sandbox", "--yolo")
        ? .unrestricted : nil
    )
  }

  func makeStartInvocation(_ request: AgentStartRequest) throws -> AgentInvocation {
    var generated: [String] = []
    if let model = request.configuration.model { generated += ["--model", model] }
    if let effort = request.configuration.reasoningEffort {
      generated += ["-c", "model_reasoning_effort=\(effort)"]
    }
    if request.configuration.executionMode == .unrestricted {
      generated.append("--dangerously-bypass-approvals-and-sandbox")
    }
    let options = finalizedOptions(generated, request: request)
    return switch request.intent {
    case .interactive: AgentInvocation(executable: "codex", arguments: options)
    case .prompt(let prompt): AgentInvocation(executable: "codex", arguments: options + [prompt])
    case .headless(let prompt): AgentInvocation(executable: "codex", arguments: ["exec"] + options + [prompt])
    }
  }
}

nonisolated private struct ClaudeCodeRuntimeAdapter: AgentRuntimeAdapter {
  let runtime: AgentProfileRuntime = .claude
  let displayName = "Claude Code"
  let supportsModelSelection = true
  let supportsReasoningEffort = true
  let executionModeOptions = AgentExecutionMode.allCases
  let accountIsolation: AgentProfileHomeRelocation? = AgentProfileHomeRelocation(
    environmentVariable: "CLAUDE_CONFIG_DIR"
  )
  let signalHooks: AgentSignalHookCapability? = AgentSignalHookCapability(
    runtime: .claude,
    nativeEvents: AgentNativeHookDecoder.nativeEvents(for: .claude)
  )
  let reasoningEffortSuggestions = ["low", "medium", "high", "xhigh", "max"]
  let modelSuggestions = [
    "claude-fable-5",
    "claude-opus-5",
    "claude-sonnet-5",
    "claude-haiku-4-5-20251001",
  ]

  func observe(arguments: [String]) -> AgentLaunchObservation {
    let bypasses =
      arguments.contains("--dangerously-skip-permissions")
      || arguments.optionValue(long: "--permission-mode") == "bypassPermissions"
    return AgentLaunchObservation(
      model: arguments.optionValue(long: "--model", short: "-m"),
      executionMode: bypasses ? .unrestricted : nil
    )
  }

  func makeStartInvocation(_ request: AgentStartRequest) throws -> AgentInvocation {
    var generated: [String] = []
    if let model = request.configuration.model { generated += ["--model", model] }
    if let effort = request.configuration.reasoningEffort { generated += ["--effort", effort] }
    if request.configuration.executionMode == .unrestricted {
      generated.append("--dangerously-skip-permissions")
    }
    let options = finalizedOptions(generated, request: request)
    return switch request.intent {
    case .interactive: AgentInvocation(executable: "claude", arguments: options)
    case .prompt(let prompt): AgentInvocation(executable: "claude", arguments: options + [prompt])
    case .headless(let prompt): AgentInvocation(executable: "claude", arguments: ["-p"] + options + [prompt])
    }
  }
}

nonisolated private struct GeminiRuntimeAdapter: AgentRuntimeAdapter {
  let runtime: AgentProfileRuntime = .gemini
  let displayName = "Gemini CLI"
  let supportsModelSelection = true
  let executionModeOptions = AgentExecutionMode.allCases
  let accountIsolation: AgentProfileHomeRelocation? = AgentProfileHomeRelocation(
    environmentVariable: "GEMINI_CLI_HOME",
    sessionRootRelativePath: ".gemini"
  )

  func observe(arguments: [String]) -> AgentLaunchObservation {
    let approves = arguments.contains("--yolo") || arguments.optionValue(long: "--approval-mode") == "yolo"
    return AgentLaunchObservation(
      model: arguments.optionValue(long: "--model", short: "-m"),
      executionMode: approves && arguments.booleanOptionIsFalse("--sandbox") ? .unrestricted : nil
    )
  }

  func makeStartInvocation(_ request: AgentStartRequest) throws -> AgentInvocation {
    var generated: [String] = []
    if let model = request.configuration.model { generated += ["--model", model] }
    if request.configuration.executionMode == .unrestricted {
      generated += ["--approval-mode", "yolo", "--sandbox=false"]
    }
    let options = finalizedOptions(generated, request: request)
    return switch request.intent {
    case .interactive: AgentInvocation(executable: "gemini", arguments: options)
    case .prompt(let prompt):
      AgentInvocation(executable: "gemini", arguments: options + ["--prompt-interactive", prompt])
    case .headless(let prompt):
      AgentInvocation(executable: "gemini", arguments: options + ["--prompt", prompt])
    }
  }
}

nonisolated private struct CursorRuntimeAdapter: AgentRuntimeAdapter {
  let runtime: AgentProfileRuntime = .cursor
  let displayName = "Cursor Agent"
  let supportsModelSelection = true
  let executionModeOptions = AgentExecutionMode.allCases

  func observe(arguments: [String]) -> AgentLaunchObservation {
    let approves = arguments.containsAny("--force", "--yolo")
    return AgentLaunchObservation(
      model: arguments.optionValue(long: "--model"),
      executionMode: approves && arguments.optionValue(long: "--sandbox") == "disabled" ? .unrestricted : nil
    )
  }

  func makeStartInvocation(_ request: AgentStartRequest) throws -> AgentInvocation {
    var generated: [String] = []
    if let model = request.configuration.model { generated += ["--model", model] }
    if request.configuration.executionMode == .unrestricted {
      generated += ["--yolo", "--sandbox", "disabled"]
    }
    let options = finalizedOptions(generated, request: request)
    return switch request.intent {
    case .interactive: AgentInvocation(executable: "cursor-agent", arguments: options)
    case .prompt(let prompt): AgentInvocation(executable: "cursor-agent", arguments: options + [prompt])
    case .headless(let prompt):
      AgentInvocation(executable: "cursor-agent", arguments: options + ["--print", prompt])
    }
  }
}

nonisolated private struct ClineRuntimeAdapter: AgentRuntimeAdapter {
  let runtime: AgentProfileRuntime = .cline
  let displayName = "Cline"
  let supportsModelSelection = true
  let supportsReasoningEffort = true
  let executionModeOptions = AgentExecutionMode.allCases
  let accountIsolation: AgentProfileHomeRelocation? = AgentProfileHomeRelocation(
    pathArguments: [
      AgentProfileHomePathArgument(option: "--config", relativePath: "config"),
      AgentProfileHomePathArgument(option: "--data-dir", relativePath: "data"),
      AgentProfileHomePathArgument(option: "--hooks-dir", relativePath: "hooks"),
    ],
    sessionRootRelativePath: "data",
    reservedEnvironmentVariables: ["CLINE_DATA_DIR"]
  )
  let reasoningEffortSuggestions = ["none", "low", "medium", "high", "xhigh"]

  func observe(arguments: [String]) -> AgentLaunchObservation {
    let autoApprove = arguments.optionValue(long: "--auto-approve")
    let executionMode: AgentExecutionMode? =
      switch autoApprove {
      case "true": .unrestricted
      case "false": .standard
      default: nil
      }
    return AgentLaunchObservation(
      model: arguments.optionValue(long: "--model", short: "-m"),
      executionMode: executionMode
    )
  }

  func makeStartInvocation(_ request: AgentStartRequest) throws -> AgentInvocation {
    var generated: [String] = []
    if let model = request.configuration.model { generated += ["--model", model] }
    if let effort = request.configuration.reasoningEffort { generated += ["--thinking", effort] }
    generated += [
      "--auto-approve",
      request.configuration.executionMode == .unrestricted ? "true" : "false",
    ]
    let options = finalizedOptions(generated, request: request)
    return switch request.intent {
    case .interactive: AgentInvocation(executable: "cline", arguments: options + ["--tui"])
    case .prompt(let prompt): AgentInvocation(executable: "cline", arguments: options + ["--tui", prompt])
    case .headless(let prompt): AgentInvocation(executable: "cline", arguments: options + [prompt])
    }
  }
}

nonisolated private struct OpenCodeRuntimeAdapter: AgentRuntimeAdapter {
  let runtime: AgentProfileRuntime = .opencode
  let displayName = "OpenCode"
  let supportsModelSelection = true
  let supportsReasoningEffort = true
  let executionModeOptions = AgentExecutionMode.allCases
  /// Relayed by the bundled `agent-hooks/opencode/prowl-hooks.ts` plugin. OpenCode creates its
  /// session lazily at the first prompt and emits nothing on `/new` or resume, so the runtime is
  /// non-announcing like Codex: the first `session.idle` verifies the channel. `permission.asked`
  /// is dropped per launch under `--auto`, where OpenCode auto-replies in the same millisecond.
  let signalHooks: AgentSignalHookCapability? = AgentSignalHookCapability(
    runtime: .opencode,
    nativeEvents: AgentNativeHookDecoder.nativeEvents(for: .opencode)
  )

  func observe(arguments: [String]) -> AgentLaunchObservation {
    AgentLaunchObservation(
      model: arguments.optionValue(long: "--model", short: "-m"),
      executionMode: arguments.contains("--auto") ? .unrestricted : nil
    )
  }

  func makeStartInvocation(_ request: AgentStartRequest) throws -> AgentInvocation {
    var generated: [String] = []
    if let model = request.configuration.model { generated += ["--model", model] }
    if let effort = request.configuration.reasoningEffort { generated += ["--variant", effort] }
    if request.configuration.executionMode == .unrestricted { generated.append("--auto") }
    let options = finalizedOptions(generated, request: request)
    return switch request.intent {
    case .interactive: AgentInvocation(executable: "opencode", arguments: options)
    case .prompt(let prompt): AgentInvocation(executable: "opencode", arguments: options + ["--prompt", prompt])
    case .headless(let prompt): AgentInvocation(executable: "opencode", arguments: ["run"] + options + [prompt])
    }
  }
}

nonisolated private struct CopilotRuntimeAdapter: AgentRuntimeAdapter {
  let runtime: AgentProfileRuntime = .copilot
  let displayName = "GitHub Copilot"
  let supportsModelSelection = true
  let supportsReasoningEffort = true
  let executionModeOptions = AgentExecutionMode.allCases
  let accountIsolation: AgentProfileHomeRelocation? = AgentProfileHomeRelocation(
    environmentVariable: "COPILOT_HOME"
  )
  /// `PermissionRequest` is excluded on purpose: it fires whenever a tool enters the
  /// permission service, including when `--allow-all-tools` auto-approves and nobody is
  /// waiting. `Notification` is the only event that means a human is actually blocked.
  /// `subagentStop` is excluded because a subagent finishing is not the main turn ending.
  let signalHooks: AgentSignalHookCapability? = AgentSignalHookCapability(
    runtime: .copilot,
    nativeEvents: AgentNativeHookDecoder.nativeEvents(for: .copilot)
  )
  let reasoningEffortSuggestions = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

  func observe(arguments: [String]) -> AgentLaunchObservation {
    AgentLaunchObservation(
      model: arguments.optionValue(long: "--model"),
      executionMode: arguments.contains("--allow-all") ? .unrestricted : nil
    )
  }

  func makeStartInvocation(_ request: AgentStartRequest) throws -> AgentInvocation {
    var generated: [String] = []
    if let model = request.configuration.model { generated += ["--model", model] }
    if let effort = request.configuration.reasoningEffort { generated += ["--reasoning-effort", effort] }
    if request.configuration.executionMode == .unrestricted { generated.append("--allow-all") }
    let options = finalizedOptions(generated, request: request)
    return switch request.intent {
    case .interactive: AgentInvocation(executable: "copilot", arguments: options)
    case .prompt(let prompt): AgentInvocation(executable: "copilot", arguments: options + ["--interactive", prompt])
    case .headless(let prompt): AgentInvocation(executable: "copilot", arguments: options + ["--prompt", prompt])
    }
  }
}

nonisolated private struct KimiRuntimeAdapter: AgentRuntimeAdapter {
  let runtime: AgentProfileRuntime = .kimi
  let displayName = "Kimi CLI"
  let supportsModelSelection = true
  let executionModeOptions = AgentExecutionMode.allCases

  func observe(arguments: [String]) -> AgentLaunchObservation {
    AgentLaunchObservation(
      model: arguments.optionValue(long: "--model", short: "-m"),
      executionMode: arguments.containsAny("--yolo", "--yes") ? .unrestricted : nil
    )
  }

  func makeStartInvocation(_ request: AgentStartRequest) throws -> AgentInvocation {
    var generated: [String] = []
    if let model = request.configuration.model { generated += ["--model", model] }
    if request.configuration.executionMode == .unrestricted { generated.append("--yolo") }
    let options = finalizedOptions(generated, request: request)
    return switch request.intent {
    case .interactive: AgentInvocation(executable: "kimi", arguments: options)
    case .prompt(let prompt): AgentInvocation(executable: "kimi", arguments: options + ["--prompt", prompt])
    case .headless(let prompt):
      AgentInvocation(executable: "kimi", arguments: options + ["--print", "--prompt", prompt])
    }
  }
}

nonisolated private struct DroidRuntimeAdapter: AgentRuntimeAdapter {
  let runtime: AgentProfileRuntime = .droid
  let displayName = "Droid"
  /// Droid has no `PermissionRequest` event; attention arrives through `Notification`.
  let signalHooks: AgentSignalHookCapability? = AgentSignalHookCapability(
    runtime: .droid,
    nativeEvents: AgentNativeHookDecoder.nativeEvents(for: .droid)
  )

  func observe(arguments _: [String]) -> AgentLaunchObservation { .init() }

  func makeStartInvocation(_ request: AgentStartRequest) throws -> AgentInvocation {
    let options = finalizedOptions([], request: request)
    return switch request.intent {
    case .interactive: AgentInvocation(executable: "droid", arguments: options)
    case .prompt(let prompt): AgentInvocation(executable: "droid", arguments: options + [prompt])
    case .headless(let prompt): AgentInvocation(executable: "droid", arguments: ["exec"] + options + [prompt])
    }
  }
}

nonisolated private struct AmpRuntimeAdapter: AgentRuntimeAdapter {
  let runtime: AgentProfileRuntime = .amp
  let displayName = "Amp"
  let supportsReasoningEffort = true
  let reasoningEffortSuggestions = ["low", "medium", "high"]

  func observe(arguments _: [String]) -> AgentLaunchObservation { .init() }

  func makeStartInvocation(_ request: AgentStartRequest) throws -> AgentInvocation {
    var generated: [String] = []
    if let effort = request.configuration.reasoningEffort { generated += ["--effort", effort] }
    let options = finalizedOptions(generated, request: request)
    return switch request.intent {
    case .interactive: AgentInvocation(executable: "amp", arguments: options)
    case .prompt:
      throw AgentRuntimeError.unsupportedStartIntent(.amp, request.intent)
    case .headless(let prompt):
      AgentInvocation(executable: "amp", arguments: options + ["--execute", prompt])
    }
  }
}

nonisolated private struct QoderRuntimeAdapter: AgentRuntimeAdapter {
  let runtime: AgentProfileRuntime = .qoder
  let displayName = "Qoder CLI"
  let supportsModelSelection = true
  let supportsReasoningEffort = true
  let executionModeOptions = AgentExecutionMode.allCases
  let accountIsolation: AgentProfileHomeRelocation? = AgentProfileHomeRelocation(
    pathArguments: [AgentProfileHomePathArgument(option: "--config-dir", relativePath: "")]
  )
  /// `PermissionRequest` is excluded on purpose: Qoder was measured firing it under
  /// `--permission-mode accept_edits` while the write was auto-approved and nobody was
  /// waiting. `StopFailure` is included because Qoder reports a failed turn that way.
  let signalHooks: AgentSignalHookCapability? = AgentSignalHookCapability(
    runtime: .qoder,
    nativeEvents: AgentNativeHookDecoder.nativeEvents(for: .qoder)
  )
  let reasoningEffortSuggestions = ["low", "medium", "high"]

  func observe(arguments: [String]) -> AgentLaunchObservation {
    let bypasses =
      arguments.contains("--dangerously-skip-permissions")
      || arguments.optionValue(long: "--permission-mode") == "bypass_permissions"
    return AgentLaunchObservation(
      model: arguments.optionValue(long: "--model", short: "-m"),
      executionMode: bypasses ? .unrestricted : nil
    )
  }

  func makeStartInvocation(_ request: AgentStartRequest) throws -> AgentInvocation {
    var generated: [String] = []
    if let model = request.configuration.model { generated += ["--model", model] }
    if let effort = request.configuration.reasoningEffort { generated += ["--reasoning-effort", effort] }
    if request.configuration.executionMode == .unrestricted {
      generated.append("--dangerously-skip-permissions")
    }
    let options = finalizedOptions(generated, request: request)
    return switch request.intent {
    case .interactive: AgentInvocation(executable: "qodercli", arguments: options)
    case .prompt(let prompt):
      AgentInvocation(executable: "qodercli", arguments: options + ["--prompt-interactive", prompt])
    case .headless(let prompt): AgentInvocation(executable: "qodercli", arguments: options + ["--print", prompt])
    }
  }
}

nonisolated private struct QwenRuntimeAdapter: AgentRuntimeAdapter {
  let runtime: AgentProfileRuntime = .qwen
  let displayName = "Qwen Code"
  let supportsModelSelection = true
  let supportsReasoningEffort = true
  let executionModeOptions = AgentExecutionMode.allCases
  let accountIsolation: AgentProfileHomeRelocation? = AgentProfileHomeRelocation(environmentVariable: "QWEN_HOME")
  let reasoningEffortSuggestions = ["low", "medium", "high", "xhigh"]

  func observe(arguments: [String]) -> AgentLaunchObservation {
    let approves = arguments.contains("--yolo") || arguments.optionValue(long: "--approval-mode") == "yolo"
    return AgentLaunchObservation(
      model: arguments.optionValue(long: "--model", short: "-m"),
      executionMode: approves && arguments.booleanOptionIsFalse("--sandbox") ? .unrestricted : nil
    )
  }

  func makeStartInvocation(_ request: AgentStartRequest) throws -> AgentInvocation {
    var generated: [String] = []
    if let model = request.configuration.model { generated += ["--model", model] }
    if let effort = request.configuration.reasoningEffort { generated += ["--reasoning-effort", effort] }
    if request.configuration.executionMode == .unrestricted {
      generated += ["--approval-mode", "yolo", "--sandbox=false"]
    }
    let options = finalizedOptions(generated, request: request)
    return switch request.intent {
    case .interactive: AgentInvocation(executable: "qwen", arguments: options)
    case .prompt(let prompt):
      AgentInvocation(executable: "qwen", arguments: options + ["--prompt-interactive", prompt])
    case .headless(let prompt): AgentInvocation(executable: "qwen", arguments: options + ["--prompt", prompt])
    }
  }
}

nonisolated private struct GrokRuntimeAdapter: AgentRuntimeAdapter {
  let runtime: AgentProfileRuntime = .grok
  let displayName = "Grok Build"
  let supportsModelSelection = true
  let supportsReasoningEffort = true
  let executionModeOptions = AgentExecutionMode.allCases
  let reasoningEffortSuggestions = ["low", "medium", "high"]

  func observe(arguments: [String]) -> AgentLaunchObservation {
    let permissionMode = arguments.optionValue(long: "--permission-mode")
    let bypassesPermissions =
      permissionMode == "bypassPermissions" || arguments.contains("--always-approve")
    let sandboxIsOff = arguments.optionValue(long: "--sandbox") == "off"
    return AgentLaunchObservation(
      model: arguments.optionValue(long: "--model", short: "-m"),
      executionMode: bypassesPermissions && sandboxIsOff
        ? .unrestricted
        : permissionMode == "default" ? .standard : nil
    )
  }

  func makeStartInvocation(_ request: AgentStartRequest) throws -> AgentInvocation {
    var generated: [String] = []
    if let model = request.configuration.model { generated += ["--model", model] }
    if let effort = request.configuration.reasoningEffort { generated += ["--reasoning-effort", effort] }
    switch request.configuration.executionMode {
    case .standard:
      generated += ["--permission-mode", "default"]
    case .unrestricted:
      generated += ["--permission-mode", "bypassPermissions", "--sandbox", "off"]
    }
    let options = finalizedOptions(generated, request: request)
    return switch request.intent {
    case .interactive: AgentInvocation(executable: "grok", arguments: options)
    case .prompt(let prompt): AgentInvocation(executable: "grok", arguments: options + [prompt])
    case .headless(let prompt): AgentInvocation(executable: "grok", arguments: options + ["--single", prompt])
    }
  }
}

nonisolated private struct PiRuntimeAdapter: AgentRuntimeAdapter {
  let runtime: AgentProfileRuntime = .pi
  let displayName = "Pi"
  let supportsModelSelection = true
  let supportsReasoningEffort = true
  let accountIsolation: AgentProfileHomeRelocation? = AgentProfileHomeRelocation(
    environmentVariable: "PI_CODING_AGENT_DIR"
  )
  /// Relayed by the bundled `agent-hooks/pi/prowl-hooks.ts` extension (`-e`). `agent_settled`
  /// is Pi's documented idle point (`agent_end` precedes it); Pi has no permission system.
  let signalHooks: AgentSignalHookCapability? = AgentSignalHookCapability(
    runtime: .pi,
    nativeEvents: AgentNativeHookDecoder.nativeEvents(for: .pi)
  )
  let reasoningEffortSuggestions = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

  func observe(arguments: [String]) -> AgentLaunchObservation {
    AgentLaunchObservation(model: arguments.optionValue(long: "--model"))
  }

  func makeStartInvocation(_ request: AgentStartRequest) throws -> AgentInvocation {
    let options = piOptions(request)
    return switch request.intent {
    case .interactive: AgentInvocation(executable: "pi", arguments: options)
    case .prompt(let prompt): AgentInvocation(executable: "pi", arguments: options + [prompt])
    case .headless(let prompt): AgentInvocation(executable: "pi", arguments: options + ["--print", prompt])
    }
  }

  private func piOptions(_ request: AgentStartRequest) -> [String] {
    var generated: [String] = []
    if let model = request.configuration.model { generated += ["--model", model] }
    if let effort = request.configuration.reasoningEffort { generated += ["--thinking", effort] }
    return finalizedOptions(generated, request: request)
  }
}

nonisolated private struct OMPRuntimeAdapter: AgentRuntimeAdapter {
  let runtime: AgentProfileRuntime = .omp
  let displayName = "Oh My Pi"
  let supportsModelSelection = true
  let supportsReasoningEffort = true
  let executionModeOptions = AgentExecutionMode.allCases
  let accountIsolation: AgentProfileHomeRelocation? = AgentProfileHomeRelocation(
    environmentVariable: "PI_CODING_AGENT_DIR"
  )
  /// Relayed by the bundled `agent-hooks/omp/prowl-hooks.ts` extension (`--hook`).
  /// `session_stop` is documented main-session only, whereas `agent_end` was measured firing
  /// once per in-process `task` sub-agent; `/new` rotates through `session_switch`.
  let signalHooks: AgentSignalHookCapability? = AgentSignalHookCapability(
    runtime: .omp,
    nativeEvents: AgentNativeHookDecoder.nativeEvents(for: .omp)
  )
  let reasoningEffortSuggestions = ["off", "minimal", "low", "medium", "high", "xhigh", "max", "auto"]

  func observe(arguments: [String]) -> AgentLaunchObservation {
    let approvalMode = arguments.optionValue(long: "--approval-mode")
    let bypasses = arguments.contains("--auto-approve") || approvalMode == "yolo"
    return AgentLaunchObservation(
      model: arguments.optionValue(long: "--model"),
      executionMode: bypasses ? .unrestricted : approvalMode == "always-ask" ? .standard : nil
    )
  }

  func makeStartInvocation(_ request: AgentStartRequest) throws -> AgentInvocation {
    var generated: [String] = []
    if let model = request.configuration.model { generated += ["--model", model] }
    if let effort = request.configuration.reasoningEffort { generated += ["--thinking", effort] }
    generated += [
      "--approval-mode",
      request.configuration.executionMode == .unrestricted ? "yolo" : "always-ask",
    ]
    let options = finalizedOptions(generated, request: request)
    return switch request.intent {
    case .interactive: AgentInvocation(executable: "omp", arguments: options)
    case .prompt(let prompt): AgentInvocation(executable: "omp", arguments: options + [prompt])
    case .headless(let prompt): AgentInvocation(executable: "omp", arguments: options + ["--print", prompt])
    }
  }
}

nonisolated extension [String] {
  fileprivate func optionValue(long: String, short: String? = nil) -> String? {
    for index in indices.reversed() {
      let argument = self[index]
      if argument == long || short == argument {
        let next = self.index(after: index)
        guard next < endIndex else { return nil }
        return self[next]
      }
      if argument.hasPrefix(long + "=") {
        return String(argument.dropFirst(long.count + 1))
      }
    }
    return nil
  }

  fileprivate func containsAny(_ values: String...) -> Bool {
    values.contains(where: contains)
  }

  fileprivate func booleanOptionIsFalse(_ option: String) -> Bool {
    contains("\(option)=false") || optionValue(long: option) == "false"
  }
}

nonisolated extension String {
  fileprivate var lastPathComponent: String {
    URL(fileURLWithPath: self).lastPathComponent
  }
}
