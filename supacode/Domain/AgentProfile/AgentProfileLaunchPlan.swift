import Foundation
import ProwlCLIShared

nonisolated struct AgentHookResources: Equatable, Sendable {
  let bundledCLIPath: String
  let socketPath: String
  /// Absolute path to the bundled Copilot hook plugin directory. `nil` outside a real app
  /// bundle, which degrades Copilot's managed hooks without affecting the other runtimes.
  var copilotPluginPath: String?
  /// Absolute paths to the bundled extension files relayed by Pi (`-e`), Oh My Pi (`--hook`),
  /// and OpenCode (an `OPENCODE_CONFIG_CONTENT` plugin). Each degrades only its own runtime.
  var piExtensionPath: String?
  var ompExtensionPath: String?
  var opencodePluginPath: String?
}

nonisolated struct AgentHookLaunchRegistration: Equatable, Sendable {
  let token: String
  let runtime: AgentNativeHookRuntime
  let launchCWD: URL
  let nativeEvents: [String: AgentSignalEvent]
  let coveredEvents: [AgentSignalEvent]
  let forwardingRecord: CodexForwardingRecord?
}

/// The compiled result of resolving a profile for one launch (docs-ai 053):
/// every decision is already made, downstream layers only execute. The same
/// plan feeds the settings editor's launch preview and the actual launch.
nonisolated struct AgentProfileLaunchPlan: Equatable, Sendable {
  let profileID: UUID
  let profileName: String
  let runtime: AgentProfileRuntime
  let invocation: AgentInvocation
  /// Argv index -> owner-controlled surface carrier. This generalizes the
  /// prompted-start carrier to large native hook settings/config arguments.
  let argumentCarriers: [Int: String]
  /// Carriers behind launch-scoped hook environment variables (OpenCode's
  /// `OPENCODE_CONFIG_CONTENT`): referenced by a `commandEnvironmentTokens`
  /// assignment and removed from the child like every other carrier.
  let environmentCarriers: [String]
  /// Present only on the execution copy immediately before surface creation.
  let hookRegistration: AgentHookLaunchRegistration?
  /// `env(1)` assignment tokens typed ahead of the invocation. The whole
  /// environment patch is launch-scoped (docs-ai 053/006): it exists for the
  /// launched agent process only — the pane's shell keeps the user's normal
  /// environment, so a manual `codex`/`claude` after the agent exits runs
  /// with the user's own account. Home paths are inlined (not secret);
  /// override values are referenced as `"$PROWL_ENV_<NAME>"` so no user
  /// value ever appears in the typed command, shell history, or scrollback.
  let commandEnvironmentTokens: [String]
  let placement: AgentProfilePlacement
  let splitDirection: UserCustomSplitDirection
  /// Carrier variables for the reference tokens, injected at surface spawn:
  /// `PROWL_ENV_<NAME>` → verbatim value. The namespace is Prowl-reserved, so
  /// nothing but the launch command reads them, and the real variable names
  /// never exist in the pane's shell.
  let surfaceEnvironment: [String: String]
  /// Validated user overrides retained in-memory for preflight facts such as PATH.
  let profileEnvironmentOverrides: [String: String]
  /// Dedicated home to provision before launch; nil for pure presets.
  let dedicatedHome: URL?
  /// Runtime-specific session root under the managed home. This is direct for
  /// most CLIs, nested for runtimes such as Gemini and Cline, and is the only
  /// rooted location the session resolver may inspect for this surface.
  let sessionConfigRoot: URL?

  init(
    profileID: UUID,
    profileName: String,
    runtime: AgentProfileRuntime,
    invocation: AgentInvocation,
    argumentCarriers: [Int: String] = [:],
    environmentCarriers: [String] = [],
    hookRegistration: AgentHookLaunchRegistration? = nil,
    commandEnvironmentTokens: [String],
    placement: AgentProfilePlacement,
    splitDirection: UserCustomSplitDirection,
    surfaceEnvironment: [String: String],
    profileEnvironmentOverrides: [String: String] = [:],
    dedicatedHome: URL?,
    sessionConfigRoot: URL? = nil
  ) {
    self.profileID = profileID
    self.profileName = profileName
    self.runtime = runtime
    self.invocation = invocation
    self.argumentCarriers = argumentCarriers
    self.environmentCarriers = environmentCarriers
    self.hookRegistration = hookRegistration
    self.commandEnvironmentTokens = commandEnvironmentTokens
    self.placement = placement
    self.splitDirection = splitDirection
    self.surfaceEnvironment = surfaceEnvironment
    self.profileEnvironmentOverrides = profileEnvironmentOverrides
    self.dedicatedHome = dedicatedHome
    self.sessionConfigRoot = sessionConfigRoot ?? dedicatedHome
  }

  /// The exact line typed into the new pane; doubles as the launch preview.
  /// Prompt text rides in the surface environment so canonical PTY limits and
  /// line-editor key interpretation cannot truncate or mutate it.
  var terminalInput: String {
    let promptCarrier =
      surfaceEnvironment[AgentProfileLaunchPlanner.promptCarrierName] == nil
      ? nil : AgentProfileLaunchPlanner.promptCarrierName
    var replacements = argumentCarriers
    if let promptCarrier, !invocation.arguments.isEmpty {
      replacements[invocation.arguments.index(before: invocation.arguments.endIndex)] = promptCarrier
    }
    let invocationInput = invocation.terminalInput(
      replacingArgumentsWithEnvironmentVariables: replacements
    )
    var environmentTokens = commandEnvironmentTokens
    let knownCarriers = [
      promptCarrier,
      surfaceEnvironment[AgentProfileLaunchPlanner.dispatchCarrierName] == nil
        ? nil : AgentProfileLaunchPlanner.dispatchCarrierName,
      surfaceEnvironment[AgentProfileLaunchPlanner.hookTokenCarrierName] == nil
        ? nil : AgentProfileLaunchPlanner.hookTokenCarrierName,
      surfaceEnvironment[AgentProfileLaunchPlanner.hookSocketCarrierName] == nil
        ? nil : AgentProfileLaunchPlanner.hookSocketCarrierName,
      surfaceEnvironment[AgentProfileLaunchPlanner.hookForwardCarrierName] == nil
        ? nil : AgentProfileLaunchPlanner.hookForwardCarrierName,
    ].compactMap { $0 }
    let carrierNames = Set(knownCarriers + Array(argumentCarriers.values) + environmentCarriers).sorted()
    for carrier in carrierNames.reversed() {
      environmentTokens.insert(contentsOf: ["-u", carrier], at: 0)
    }
    guard !environmentTokens.isEmpty else { return invocationInput }
    return (["env"] + environmentTokens + [invocationInput]).joined(separator: " ")
  }

  var previewText: String { terminalInput }

  func applyingManagedHook(
    _ prepared: AgentHookPreparedInvocation,
    resources: AgentHookResources,
    launchCWD: URL,
    token: String,
    nativeEvents: [String: AgentSignalEvent] = [:],
    coveredEvents: [AgentSignalEvent],
    forwardingRecord: CodexForwardingRecord? = nil
  ) -> AgentProfileLaunchPlan {
    guard let runtime = AgentNativeHookRuntime(rawValue: runtime.rawValue) else { return self }
    var environment = surfaceEnvironment
    var carriers: [Int: String] = [:]
    for (offset, entry) in prepared.argumentValues.sorted(by: { $0.key < $1.key }).enumerated() {
      let carrier = "PROWL_LAUNCH_HOOK_ARG_\(offset)"
      carriers[entry.key] = carrier
      environment[carrier] = entry.value
    }
    environment[AgentProfileLaunchPlanner.hookTokenCarrierName] = token
    environment[AgentProfileLaunchPlanner.hookSocketCarrierName] = resources.socketPath
    var commandTokens =
      commandEnvironmentTokens + [
        "\(AgentNativeHookInput.tokenEnvironmentKey)=\"$\(AgentProfileLaunchPlanner.hookTokenCarrierName)\"",
        "\(ProwlSocket.environmentKey)=\"$\(AgentProfileLaunchPlanner.hookSocketCarrierName)\"",
      ]
    // Hook environment variables ride the same way as hook argv values: the child sees the real
    // variable, the typed command only ever names the carrier.
    var environmentCarriers: [String] = []
    for (offset, entry) in prepared.environmentValues.sorted(by: { $0.key < $1.key }).enumerated() {
      let carrier = "PROWL_LAUNCH_HOOK_ENV_\(offset)"
      environmentCarriers.append(carrier)
      environment[carrier] = entry.value
      commandTokens.append("\(entry.key)=\"$\(carrier)\"")
    }
    // Only Codex's bridge reads a private file out of the environment; Droid's settings file
    // is named directly in its own argv, so its locator must not reach the child process.
    if let forwardingRecord, runtime == .codex {
      environment[AgentProfileLaunchPlanner.hookForwardCarrierName] = forwardingRecord.locator.path(
        percentEncoded: false
      )
      commandTokens.append(
        "\(AgentNativeHookInput.forwardRecordEnvironmentKey)=\"$\(AgentProfileLaunchPlanner.hookForwardCarrierName)\""
      )
    }
    return AgentProfileLaunchPlan(
      profileID: profileID,
      profileName: profileName,
      runtime: self.runtime,
      invocation: prepared.invocation,
      argumentCarriers: carriers,
      environmentCarriers: environmentCarriers,
      hookRegistration: AgentHookLaunchRegistration(
        token: token,
        runtime: runtime,
        launchCWD: launchCWD.standardizedFileURL,
        nativeEvents: nativeEvents,
        coveredEvents: coveredEvents,
        forwardingRecord: forwardingRecord
      ),
      commandEnvironmentTokens: commandTokens,
      placement: placement,
      splitDirection: splitDirection,
      surfaceEnvironment: environment,
      profileEnvironmentOverrides: profileEnvironmentOverrides,
      dedicatedHome: dedicatedHome,
      sessionConfigRoot: sessionConfigRoot
    )
  }

  /// A workflow `launch` role (docs-ai 063 B3, decision W6): replaces the placeholder prompt the
  /// frozen plan was compiled with by the rendered kickoff prompt (its own protocol block, not
  /// S2's dispatch protocol) and attaches the `PROWL_WORKFLOW_*` values as child-only carriers,
  /// exactly like `attachingDispatch` carries `PROWL_DISPATCH_ID`. Nothing here reaches the
  /// typed command or the pane's shell by name.
  func attachingWorkflow(prompt: String, environment values: [String: String]) throws -> AgentProfileLaunchPlan {
    guard !invocation.arguments.isEmpty, surfaceEnvironment[AgentProfileLaunchPlanner.promptCarrierName] != nil
    else {
      throw AgentProfileLaunchPlanError.dispatchRequiresPrompt
    }
    guard !prompt.contains("\0"), !values.contains(where: { $0.key.contains("\0") || $0.value.contains("\0") })
    else {
      throw AgentProfileLaunchPlanError.promptContainsNUL
    }
    var arguments = invocation.arguments
    arguments[arguments.index(before: arguments.endIndex)] = prompt
    var environment = surfaceEnvironment
    environment[AgentProfileLaunchPlanner.promptCarrierName] = prompt
    var commandTokens = commandEnvironmentTokens
    var carriers = environmentCarriers
    for (offset, entry) in values.sorted(by: { $0.key < $1.key }).enumerated() {
      let carrier = "\(AgentProfileLaunchPlanner.workflowCarrierPrefix)\(offset)"
      carriers.append(carrier)
      environment[carrier] = entry.value
      commandTokens.append("\(entry.key)=\"$\(carrier)\"")
    }
    return AgentProfileLaunchPlan(
      profileID: profileID,
      profileName: profileName,
      runtime: runtime,
      invocation: AgentInvocation(executable: invocation.executable, arguments: arguments),
      argumentCarriers: argumentCarriers,
      environmentCarriers: carriers,
      hookRegistration: hookRegistration,
      commandEnvironmentTokens: commandTokens,
      placement: placement,
      splitDirection: splitDirection,
      surfaceEnvironment: environment,
      profileEnvironmentOverrides: profileEnvironmentOverrides,
      dedicatedHome: dedicatedHome,
      sessionConfigRoot: sessionConfigRoot
    )
  }

  func attachingDispatch(id: String, userPrompt: String) throws -> AgentProfileLaunchPlan {
    guard !id.isEmpty, !id.contains("\0"), !userPrompt.contains("\0"),
      !invocation.arguments.isEmpty,
      surfaceEnvironment[AgentProfileLaunchPlanner.promptCarrierName] != nil
    else {
      throw AgentProfileLaunchPlanError.dispatchRequiresPrompt
    }
    let renderedPrompt = AgentDispatchPrompt.render(userPrompt: userPrompt)
    var arguments = invocation.arguments
    arguments[arguments.index(before: arguments.endIndex)] = renderedPrompt
    var environment = surfaceEnvironment
    environment[AgentProfileLaunchPlanner.promptCarrierName] = renderedPrompt
    environment[AgentProfileLaunchPlanner.dispatchCarrierName] = id
    var commandTokens = commandEnvironmentTokens
    commandTokens.append(
      "\(DispatchCompleteInput.environmentKey)=\"$\(AgentProfileLaunchPlanner.dispatchCarrierName)\""
    )
    return AgentProfileLaunchPlan(
      profileID: profileID,
      profileName: profileName,
      runtime: runtime,
      invocation: AgentInvocation(executable: invocation.executable, arguments: arguments),
      argumentCarriers: argumentCarriers,
      environmentCarriers: environmentCarriers,
      hookRegistration: hookRegistration,
      commandEnvironmentTokens: commandTokens,
      placement: placement,
      splitDirection: splitDirection,
      surfaceEnvironment: environment,
      profileEnvironmentOverrides: profileEnvironmentOverrides,
      dedicatedHome: dedicatedHome,
      sessionConfigRoot: sessionConfigRoot
    )
  }
}

/// One deterministic profile launch request shared by the CLI, workflow runner,
/// and terminal layer. The compiled plan remains the single adapter-rendered
/// invocation/environment seam; placement and directory are per-launch choices.
nonisolated struct AgentProfileLaunchRequest: Equatable, Sendable {
  nonisolated enum Placement: Equatable, Sendable {
    case tab(background: Bool)
    case split(
      anchor: UUID?,
      direction: UserCustomSplitDirection,
      background: Bool
    )
  }

  let plan: AgentProfileLaunchPlan
  let placement: Placement
  let workingDirectoryOverride: URL?
  let inheritanceAnchor: UUID?
  let title: String?

  init(
    plan: AgentProfileLaunchPlan,
    placement: Placement,
    workingDirectoryOverride: URL? = nil,
    inheritanceAnchor: UUID? = nil,
    title: String? = nil
  ) {
    self.plan = plan
    self.placement = placement
    self.workingDirectoryOverride = workingDirectoryOverride
    self.inheritanceAnchor = inheritanceAnchor
    self.title = title
  }
}

nonisolated struct FrozenAgentProfileLaunchContext: Equatable, Sendable {
  let request: AgentProfileLaunchRequest
  let inheritedCWD: URL
  let anchorSurfaceID: UUID?
  let tracksFocusedAnchor: Bool
  let tracksInheritedCWD: Bool

  init(
    request: AgentProfileLaunchRequest,
    inheritedCWD: URL,
    anchorSurfaceID: UUID?,
    tracksFocusedAnchor: Bool = false,
    tracksInheritedCWD: Bool = false
  ) {
    self.request = request
    self.inheritedCWD = inheritedCWD
    self.anchorSurfaceID = anchorSurfaceID
    self.tracksFocusedAnchor = tracksFocusedAnchor
    self.tracksInheritedCWD = tracksInheritedCWD
  }
}

nonisolated struct PreparedAgentProfileLaunch: Equatable, Sendable {
  let context: FrozenAgentProfileLaunchContext
  let warnings: [LifecycleCommandWarning]
}

nonisolated struct LaunchedSurface: Equatable, Sendable {
  let tabID: TerminalTabID
  let surfaceID: UUID
}

nonisolated enum AgentProfileLaunchError: Error, Equatable, Sendable {
  case homeProvisioningFailed
  case splitAnchorUnavailable
  case splitCreationFailed(SplitCreationError)
  case tabCreationFailed
  case launchedSurfaceMissing(TerminalTabID)
  case hookRegistrationFailed
  case surfaceCreationFailed
  case preparationCancelled
}

/// Which env variable names a profile override may set, shared by the planner
/// (filtering) and the editor (inline row diagnostics) so they can never
/// disagree (docs-ai 053/004).
nonisolated enum AgentProfileEnvironmentPolicy {
  enum RowIssue: Equatable, Sendable {
    case invalidName
    case reservedName
    case invalidValue
  }

  /// Account-home variables come from the adapters, not a hardcoded list; the
  /// `PROWL_` prefix protects the worktree/root/pane facts Prowl injects itself.
  /// Letting an override set `CODEX_HOME` on an unbound profile would bypass
  /// home provisioning, deletion protection, and rooted session detection —
  /// custom homes are a separate capability, not an env-table backdoor.
  static var reservedNames: Set<String> {
    Set(
      AgentProfileRuntime.allCases.compactMap {
        AgentRuntimeAdapterRegistry.profileAdapter(for: $0)?.accountIsolation?.reservedEnvironmentVariables
      }
      .flatMap { $0 }
    )
  }

  static func isValidName(_ name: String) -> Bool {
    guard let first = name.utf8.first else { return false }
    guard first == UInt8(ascii: "_") || isASCIILetter(first) else { return false }
    return name.utf8.dropFirst().allSatisfy {
      $0 == UInt8(ascii: "_") || isASCIILetter($0) || isASCIIDigit($0)
    }
  }

  /// `HOME` is reserved for the same reason as the account-home variables:
  /// relocating it moves every runtime's *default* home (`$HOME/.claude`,
  /// `$HOME/.codex`), bypassing home provisioning, deletion protection, and
  /// rooted session detection without ever flipping the binding toggle.
  static func isReserved(_ name: String) -> Bool {
    name.hasPrefix("PROWL_") || name == "HOME" || reservedNames.contains(name)
  }

  /// A NUL would be silently truncated at the C-string boundary; refuse the
  /// row instead of launching with a value the user never wrote.
  static func isValidValue(_ value: String) -> Bool {
    !value.contains("\0")
  }

  /// nil for a row the planner will apply; blank names are in-progress rows,
  /// reported as nil issue too — they are ignored without being an error.
  static func issue(for override: AgentProfileEnvironmentOverride) -> RowIssue? {
    let name = override.trimmedName
    guard !name.isEmpty else { return nil }
    if !isValidName(name) { return .invalidName }
    if isReserved(name) { return .reservedName }
    if !isValidValue(override.value) { return .invalidValue }
    return nil
  }

  /// Carrier variable in the surface environment holding an override's value.
  /// The `PROWL_` namespace is already reserved, so user rows can't collide
  /// with a carrier, and the validated POSIX name keeps the reference token
  /// (`NAME="$PROWL_ENV_NAME"`) free of any user-authored shell text.
  static func carrierName(for name: String) -> String {
    "PROWL_ENV_\(name)"
  }

  /// The applied subset: trimmed names, invalid/reserved rows dropped, later
  /// duplicates win (shell-export semantics). Values stay verbatim — an empty
  /// value legitimately sets the variable to the empty string.
  static func effectiveOverrides(
    _ overrides: [AgentProfileEnvironmentOverride]
  ) -> [String: String] {
    var environment: [String: String] = [:]
    for override in overrides {
      let name = override.trimmedName
      guard !name.isEmpty, issue(for: override) == nil else { continue }
      environment[name] = override.value
    }
    return environment
  }

  private static func isASCIILetter(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
      || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
  }

  private static func isASCIIDigit(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
  }
}

/// The editor's conservative execution-mode disclosure. This is not a full
/// parser for a runtime's final configuration: an explicit Unrestricted
/// picker selection keeps its warning even when later Advanced arguments may
/// override generated flags. Those arguments are authoritative user input.
///
/// CLI flag surfaces evolve (`--sandbox danger-full-access`,
/// `--ask-for-approval never`, arbitrary `-c` overrides), so any recognition
/// list goes stale: instead of chasing it, unrecognized extra arguments
/// downgrade the claim to "follows your command line" — the display never
/// asserts Standard it cannot prove (docs-ai 053, review round 2).
nonisolated enum AgentProfileEffectiveExecutionMode: Equatable, Sendable {
  case standard
  case unrestricted
  case followsExtraArguments
}

nonisolated extension AgentProfile {
  /// Extra arguments are respected as explicit user configuration — never
  /// blocked or stripped. For a Standard selection, a bypass flag the
  /// adapter's `observe` recognizes (`--yolo`, `--dangerously-*`,
  /// `--permission-mode bypassPermissions`) upgrades the disclosure to
  /// `.unrestricted`; any other extra argument defers it entirely.
  var effectiveExecutionMode: AgentProfileEffectiveExecutionMode {
    let selectableModes =
      AgentRuntimeAdapterRegistry.profileAdapter(for: runtime)?.executionModeOptions ?? []
    if executionMode == .unrestricted, selectableModes.contains(.unrestricted) {
      return .unrestricted
    }
    let tokens = ShellWordSplitter.split(extraArguments)
    guard !tokens.isEmpty else { return .standard }
    let observed = AgentRuntimeAdapterRegistry.observe(runtime: runtime, arguments: tokens)
    return observed.executionMode == .unrestricted ? .unrestricted : .followsExtraArguments
  }
}

nonisolated enum AgentProfileLaunchPlanError: Error, Equatable, Sendable {
  case runtimeUnavailable(AgentProfileRuntime)
  case accountIsolationUnsupported(AgentProfileRuntime)
  case promptContainsNUL
  case promptArgumentUnavailable(AgentProfileRuntime)
  case dispatchRequiresPrompt
  case homeEscapesBase(URL)
  case homeIsSymbolicLink(URL)
}

nonisolated enum AgentProfileLaunchPlanner {
  /// Reserved surface-environment carrier for prompted starts. The prompt is
  /// expanded as one quoted argv token and never enters Ghostty initial_input.
  static let promptCarrierName = "PROWL_LAUNCH_PROMPT"
  /// The surface keeps only this opaque carrier. `env(1)` copies its value to
  /// PROWL_DISPATCH_ID for the launched runtime and removes the carrier from
  /// that child, so neither the pane shell nor a later manual runtime receives
  /// a stale public dispatch context.
  static let dispatchCarrierName = "PROWL_LAUNCH_DISPATCH"
  static let hookTokenCarrierName = "PROWL_LAUNCH_HOOK_TOKEN"
  static let hookSocketCarrierName = "PROWL_LAUNCH_HOOK_SOCKET"
  static let hookForwardCarrierName = "PROWL_LAUNCH_HOOK_FORWARD"
  /// `PROWL_LAUNCH_WORKFLOW_<n>`: one carrier per workflow child-environment value (063 B3).
  static let workflowCarrierPrefix = "PROWL_LAUNCH_WORKFLOW_"

  /// Resolves a profile into one launch plan. Pure: no filesystem access —
  /// home provisioning happens at the launch boundary, not here.
  static func plan(
    for profile: AgentProfile,
    intent: AgentStartIntent = .interactive,
    homeBaseDirectory: URL,
    dispatchID: String? = nil
  ) throws -> AgentProfileLaunchPlan {
    guard let adapter = AgentRuntimeAdapterRegistry.profileAdapter(for: profile.runtime) else {
      throw AgentProfileLaunchPlanError.runtimeUnavailable(profile.runtime)
    }
    let configuration = AgentLaunchConfiguration(
      model: profile.model,
      executionMode: profile.executionMode,
      reasoningEffort: profile.reasoningEffort,
      extraArguments: ShellWordSplitter.split(profile.extraArguments)
    )
    // The whole patch renders as launch-scoped `env` tokens (docs-ai
    // 053/006). The home token leads: it is the launch's identity, and the
    // reserved-name policy already guarantees no user row can carry the same
    // name — the account isolation reasoning stays provable.
    var tokens: [String] = []
    var surfaceEnvironment: [String: String] = [:]
    var dedicatedHome: URL?
    var sessionConfigRoot: URL?
    if profile.bindsDedicatedHome {
      guard let relocation = adapter.accountIsolation else {
        throw AgentProfileLaunchPlanError.accountIsolationUnsupported(profile.runtime)
      }
      let home = dedicatedHomeDirectory(for: profile.id, base: homeBaseDirectory)
      guard isContained(home, in: homeBaseDirectory) else {
        throw AgentProfileLaunchPlanError.homeEscapesBase(home)
      }
      if let variable = relocation.environmentVariable {
        // Inlined literal: the UUID-derived path is not a secret, and seeing
        // it in the preview documents which home the launch binds.
        tokens.append("\(variable)=\(AgentInvocation.shellQuote(pathString(home)))")
      }
      dedicatedHome = home
      sessionConfigRoot = relocation.sessionConfigRoot(for: home)
    }
    let effectiveIntent: AgentStartIntent
    if let dispatchID {
      guard case .prompt(let prompt) = intent else {
        throw AgentProfileLaunchPlanError.dispatchRequiresPrompt
      }
      guard !dispatchID.isEmpty, !dispatchID.contains("\0") else {
        throw AgentProfileLaunchPlanError.dispatchRequiresPrompt
      }
      effectiveIntent = .prompt(AgentDispatchPrompt.render(userPrompt: prompt))
    } else {
      effectiveIntent = intent
    }
    let invocation = try AgentRuntimeAdapterRegistry.makeStartInvocation(
      AgentStartRequest(
        runtime: profile.runtime,
        intent: effectiveIntent,
        configuration: configuration,
        dedicatedHome: dedicatedHome
      )
    )
    if let prompt = effectiveIntent.promptText {
      guard !prompt.contains("\0") else {
        throw AgentProfileLaunchPlanError.promptContainsNUL
      }
      guard invocation.arguments.last == prompt else {
        throw AgentProfileLaunchPlanError.promptArgumentUnavailable(profile.runtime)
      }
      surfaceEnvironment[promptCarrierName] = prompt
    }
    if let dispatchID {
      surfaceEnvironment[dispatchCarrierName] = dispatchID
      tokens.append("\(DispatchCompleteInput.environmentKey)=\"$\(dispatchCarrierName)\"")
    }
    let overrides = AgentProfileEnvironmentPolicy.effectiveOverrides(profile.environmentOverrides)
    for name in overrides.keys.sorted() {
      let carrier = AgentProfileEnvironmentPolicy.carrierName(for: name)
      tokens.append("\(name)=\"$\(carrier)\"")
      surfaceEnvironment[carrier] = overrides[name]
    }

    return AgentProfileLaunchPlan(
      profileID: profile.id,
      profileName: profile.name,
      runtime: profile.runtime,
      invocation: invocation,
      commandEnvironmentTokens: tokens,
      placement: profile.placement,
      splitDirection: profile.splitDirection,
      surfaceEnvironment: surfaceEnvironment,
      profileEnvironmentOverrides: overrides,
      dedicatedHome: dedicatedHome,
      sessionConfigRoot: sessionConfigRoot
    )
  }

  /// Homes derive from the UUID alone — never from the display name or any
  /// user-supplied path (docs-ai 053).
  static func dedicatedHomeDirectory(for profileID: UUID, base: URL) -> URL {
    base
      .appending(path: profileID.uuidString, directoryHint: .isDirectory)
      .standardizedFileURL
  }

  /// Directory URLs render with a trailing slash in `path()`; environment
  /// values and comparisons want the bare path.
  static func pathString(_ url: URL) -> String {
    let path = url.standardizedFileURL.path(percentEncoded: false)
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  static func isContained(_ url: URL, in base: URL) -> Bool {
    let baseComponents = base.standardizedFileURL.pathComponents
    let urlComponents = url.standardizedFileURL.pathComponents
    guard urlComponents.count > baseComponents.count else { return false }
    return Array(urlComponents.prefix(baseComponents.count)) == baseComponents
  }
}

nonisolated enum AgentDispatchPrompt {
  static let protocolVersion = 1
  /// Origin marker on text Prowl types into a live agent, shared with `HandoffInjection`.
  static let injectedPrefix = "[Prowl] "

  /// The text `agents dispatch` types into an existing agent pane: the same prompt and
  /// protocol block a prompted launch passes through argv, behind the origin marker so the
  /// agent (and a person reading the transcript) can tell Prowl authored the line.
  static func renderInjected(userPrompt: String) -> String {
    injectedPrefix + render(userPrompt: userPrompt)
  }

  static func render(userPrompt: String) -> String {
    """
    \(userPrompt)

    ---
    Prowl dispatch completion protocol v\(protocolVersion):
    Before ending this task, choose exactly one terminal outcome and make this command your final tool action:
    prowl agents dispatch-complete --outcome succeeded|failed --summary "<concise result>"
    Use succeeded only when the assigned work is complete and verified. Use failed when it cannot be completed.
    Keep the required summary to a single line with no control characters, and explain the result clearly.
    Do not omit the command; Prowl supplies its dispatch context
    automatically.
    """
  }
}

/// Creates a dedicated profile home right before launch. The containment
/// check is the same hard gate used for deletion: file operations only ever
/// touch UUID-derived paths inside the base — never a real agent home.
nonisolated enum AgentProfileHomeProvisioner {
  static func provision(home: URL, base: URL, fileManager: FileManager = .default) throws {
    guard AgentProfileLaunchPlanner.isContained(home, in: base) else {
      throw AgentProfileLaunchPlanError.homeEscapesBase(home)
    }
    try validatePhysicalContainment(home: home, base: base, fileManager: fileManager)
    try fileManager.createDirectory(
      at: home,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    // createDirectory attributes only apply on creation; enforce owner-only
    // permissions for pre-existing homes as well.
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: home.path(percentEncoded: false)
    )
  }

  /// Lexical containment is not enough: a `<uuid>` leaf replaced by a symlink
  /// to a real agent home (`~/.codex`) passes the string check while every
  /// following file operation lands on the link target. Reject a symlink leaf
  /// outright, then require the *canonical* home to stay inside the
  /// *canonical* base — which deliberately keeps a symlinked base itself
  /// legal (e.g. `~/.prowl` living on a synced volume resolves consistently
  /// on both sides of the comparison).
  static func validatePhysicalContainment(
    home: URL,
    base: URL,
    fileManager: FileManager = .default
  ) throws {
    let homePath = AgentProfileLaunchPlanner.pathString(home)
    if let attributes = try? fileManager.attributesOfItem(atPath: homePath),
      attributes[.type] as? FileAttributeType == .typeSymbolicLink
    {
      throw AgentProfileLaunchPlanError.homeIsSymbolicLink(home)
    }
    // `resolvingSymlinksInPath()` leaves ancestors unresolved when the leaf
    // does not exist yet (first provision), so resolve the parent — which
    // must exist for the comparison to mean anything — and reattach the leaf.
    // The leaf itself was just proven not to be a symlink.
    let canonicalHome =
      home
      .deletingLastPathComponent()
      .resolvingSymlinksInPath()
      .appending(path: home.lastPathComponent, directoryHint: .isDirectory)
    let canonicalBase = base.resolvingSymlinksInPath()
    guard AgentProfileLaunchPlanner.isContained(canonicalHome, in: canonicalBase) else {
      throw AgentProfileLaunchPlanError.homeEscapesBase(home)
    }
  }
}
