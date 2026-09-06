import Foundation
import ProwlCLIShared

/// Droid's `--settings` takes a path only, so its merged object must be written to an
/// owner-only file before the argv can name it. The merge is pure; the write belongs to the
/// main-actor store, so the preparer hands this back and the manager completes it.
nonisolated struct PendingManagedHookSettingsFile: Equatable, Sendable {
  let data: Data
  let invocation: AgentInvocation
  let promptArgumentIndex: Int?
}

nonisolated struct AgentManagedHookPreparation: Equatable, Sendable {
  let preparedInvocation: AgentHookPreparedInvocation?
  let capability: AgentSignalHookCapability?
  let launchCWD: URL
  let forwardingArgv: [String]?
  var pendingSettingsFile: PendingManagedHookSettingsFile?
  let warning: LifecycleCommandWarning?
}

nonisolated enum AgentManagedHookPreparer {
  private struct CodexPreparationOptions {
    let promptIndex: Int?
    let shellEnvironment: CodexShellLaunchEnvironment?
    let configReadProcess: CodexConfigReadProcess
  }

  private struct CodexRenderingOptions {
    let promptIndex: Int?
    let forwardingArgv: [String]?
  }

  private struct OpenCodePreparationOptions {
    let promptIndex: Int?
    let environmentResolver: OpenCodeEnvironmentResolver?
  }

  private struct SettingsRuntimeOptions {
    let promptIndex: Int?
    let droidSettingsEnvironmentResolver: DroidSettingsEnvironmentResolver?
    let settingsReadFile: (@Sendable (URL, Int) -> ClaudeSettingsReadResult)?
  }

  typealias DroidSettingsEnvironmentResolver =
    @Sendable (URL, String?) async -> DroidSettingsEnvironmentProbe.Resolution
  typealias OpenCodeEnvironmentResolver =
    @Sendable (URL, String?) async -> ShellEnvironmentProbe.Resolution

  static func prepare(
    plan: AgentProfileLaunchPlan,
    inheritedCWD: URL,
    resources: AgentHookResources?,
    codexShellEnvironment: CodexShellLaunchEnvironment? = nil,
    codexConfigReadProcess: CodexConfigReadProcess = CodexConfigReadProcess(),
    droidSettingsEnvironmentResolver: DroidSettingsEnvironmentResolver? = nil,
    settingsReadFile: (@Sendable (URL, Int) -> ClaudeSettingsReadResult)? = nil,
    openCodeEnvironmentResolver: OpenCodeEnvironmentResolver? = nil
  ) async -> AgentManagedHookPreparation {
    guard
      let capability = AgentRuntimeAdapterRegistry.profileAdapter(for: plan.runtime)?.signalHooks
    else {
      return AgentManagedHookPreparation(
        preparedInvocation: nil,
        capability: nil,
        launchCWD: inheritedCWD,
        forwardingArgv: nil,
        pendingSettingsFile: nil,
        warning: nil
      )
    }
    guard let resources,
      resources.bundledCLIPath.hasPrefix("/"),
      FileManager.default.isExecutableFile(atPath: resources.bundledCLIPath)
    else {
      return degraded(
        plan: plan,
        capability: capability,
        launchCWD: inheritedCWD,
        message: "The bundled Prowl hook bridge is unavailable."
      )
    }
    let promptIndex =
      plan.surfaceEnvironment[AgentProfileLaunchPlanner.promptCarrierName] == nil
      ? nil : plan.invocation.arguments.indices.last
    switch capability.runtime {
    case .claude:
      return await prepareClaude(
        plan: plan,
        capability: capability,
        inheritedCWD: inheritedCWD,
        resources: resources,
        promptIndex: promptIndex
      )
    case .codex:
      return await prepareCodex(
        plan: plan,
        capability: capability,
        inheritedCWD: inheritedCWD,
        resources: resources,
        options: CodexPreparationOptions(
          promptIndex: promptIndex,
          shellEnvironment: codexShellEnvironment,
          configReadProcess: codexConfigReadProcess
        )
      )
    case .copilot:
      return prepareCopilot(
        plan: plan,
        capability: capability,
        inheritedCWD: inheritedCWD,
        resources: resources,
        promptIndex: promptIndex
      )
    case .droid, .qoder:
      return await prepareSettingsRuntime(
        plan: plan,
        capability: capability,
        inheritedCWD: inheritedCWD,
        resources: resources,
        options: SettingsRuntimeOptions(
          promptIndex: promptIndex,
          droidSettingsEnvironmentResolver: droidSettingsEnvironmentResolver,
          settingsReadFile: settingsReadFile
        )
      )
    case .pi, .omp:
      return prepareExtensionRuntime(
        plan: plan,
        capability: capability,
        inheritedCWD: inheritedCWD,
        resources: resources,
        promptIndex: promptIndex
      )
    case .opencode:
      return await prepareOpenCode(
        plan: plan,
        capability: capability,
        inheritedCWD: inheritedCWD,
        resources: resources,
        options: OpenCodePreparationOptions(
          promptIndex: promptIndex,
          environmentResolver: openCodeEnvironmentResolver
        )
      )
    }
  }

  /// Pi and Oh My Pi load Prowl's bundled extension through an additive flag; nothing is
  /// merged. Pi refuses to start when an `-e` path is missing, so a missing bundled file
  /// degrades before launch for both.
  private static func prepareExtensionRuntime(
    plan: AgentProfileLaunchPlan,
    capability: AgentSignalHookCapability,
    inheritedCWD: URL,
    resources: AgentHookResources,
    promptIndex: Int?
  ) -> AgentManagedHookPreparation {
    let isPi = capability.runtime == .pi
    let displayName = isPi ? "Pi" : "Oh My Pi"
    guard let extensionPath = isPi ? resources.piExtensionPath : resources.ompExtensionPath,
      extensionPath.hasPrefix("/"),
      FileManager.default.isReadableFile(atPath: extensionPath)
    else {
      return degraded(
        plan: plan,
        capability: capability,
        launchCWD: inheritedCWD,
        message: "The bundled \(displayName) hook extension is unavailable."
      )
    }
    // Oh My Pi's `--cwd` (last wins) changes the directory its extensions report; Pi has no
    // such option.
    let scan: ManagedHookWorkingDirectory.Scan =
      isPi
      ? .inherited
      : ManagedHookWorkingDirectory.scan(
        arguments: plan.invocation.arguments,
        optionNames: ["--cwd"],
        precedence: .lastWins,
        promptArgumentIndex: promptIndex
      )
    guard let launchCWD = ManagedHookWorkingDirectory.effective(inherited: inheritedCWD, scan: scan) else {
      return degraded(
        plan: plan,
        capability: capability,
        launchCWD: inheritedCWD,
        message: "The \(displayName) working directory option could not be resolved."
      )
    }
    return AgentManagedHookPreparation(
      preparedInvocation: ExtensionFlagHookRenderer.prepare(
        invocation: plan.invocation,
        option: isPi ? "-e" : "--hook",
        extensionPath: extensionPath,
        promptArgumentIndex: promptIndex
      ),
      capability: capability,
      launchCWD: launchCWD,
      forwardingArgv: nil,
      pendingSettingsFile: nil,
      warning: nil
    )
  }

  /// OpenCode's plugin rides `OPENCODE_CONFIG_CONTENT`, which the launch may already carry from
  /// a Profile override or the user's shell rc. A Profile override wins; otherwise the login
  /// shell is probed for both that variable and `OPENCODE_PURE`, and a probe that cannot run
  /// degrades rather than override. `--auto` auto-replies `permission.asked` in the same
  /// millisecond (measured), so that event leaves the registered table for such launches.
  private static func prepareOpenCode(
    plan: AgentProfileLaunchPlan,
    capability: AgentSignalHookCapability,
    inheritedCWD: URL,
    resources: AgentHookResources,
    options: OpenCodePreparationOptions
  ) async -> AgentManagedHookPreparation {
    let promptIndex = options.promptIndex
    let environmentResolver = options.environmentResolver
    guard let pluginPath = resources.opencodePluginPath,
      pluginPath.hasPrefix("/"),
      FileManager.default.isReadableFile(atPath: pluginPath)
    else {
      return degraded(
        plan: plan,
        capability: capability,
        launchCWD: inheritedCWD,
        message: "The bundled OpenCode hook plugin is unavailable."
      )
    }
    let arguments = plan.invocation.arguments
    guard
      var launchCWD = ManagedHookWorkingDirectory.effective(
        inherited: inheritedCWD,
        scan: OpenCodeLaunchDirectory.scan(arguments: arguments, promptArgumentIndex: promptIndex)
      )
    else {
      return degraded(
        plan: plan,
        capability: capability,
        launchCWD: inheritedCWD,
        message: "The OpenCode project directory could not be resolved."
      )
    }
    // OpenCode refuses to start in a directory that does not exist, so a candidate that is not
    // one can only be the value of an option the scanner does not know; the hooks will report
    // the launch directory in that case.
    var isDirectory: ObjCBool = false
    if !FileManager.default.fileExists(atPath: launchCWD.path(percentEncoded: false), isDirectory: &isDirectory)
      || !isDirectory.boolValue
    {
      launchCWD = inheritedCWD
    }
    let overrides = plan.profileEnvironmentOverrides
    var content = overrides[OpenCodeHookPluginPreparer.contentVariableName]
    var pure = overrides[OpenCodeHookPluginPreparer.pureVariableName]
    if content == nil || pure == nil, let environmentResolver {
      switch await environmentResolver(inheritedCWD, overrides["PATH"]) {
      case .failed:
        return degraded(
          plan: plan,
          capability: capability,
          launchCWD: launchCWD,
          message: "The OpenCode launch environment could not be resolved; launching unchanged."
        )
      case .values(let values):
        if content == nil { content = values[OpenCodeHookPluginPreparer.contentVariableName] ?? nil }
        if pure == nil { pure = values[OpenCodeHookPluginPreparer.pureVariableName] ?? nil }
      }
    }
    if OpenCodeHookPluginPreparer.isPure(environmentValue: pure) {
      return degraded(
        plan: plan,
        capability: capability,
        launchCWD: launchCWD,
        message: "Managed OpenCode hooks are unavailable when OPENCODE_PURE is set; launching unchanged."
      )
    }
    let outcome = OpenCodeHookPluginPreparer.prepare(
      invocation: plan.invocation,
      pluginPath: pluginPath,
      existingContent: content,
      promptArgumentIndex: promptIndex
    )
    guard let prepared = outcome.prepared else {
      return AgentManagedHookPreparation(
        preparedInvocation: nil,
        capability: capability,
        launchCWD: launchCWD,
        forwardingArgv: nil,
        pendingSettingsFile: nil,
        warning: outcome.warning
      )
    }
    var effectiveCapability = capability
    if OpenCodeHookPluginPreparer.containsAutoFlag(arguments, promptArgumentIndex: promptIndex) {
      effectiveCapability = AgentSignalHookCapability(
        runtime: capability.runtime,
        nativeEvents: capability.nativeEvents.filter { $0.key != "permission.asked" }
      )
    }
    return AgentManagedHookPreparation(
      preparedInvocation: prepared,
      capability: effectiveCapability,
      launchCWD: launchCWD,
      forwardingArgv: nil,
      pendingSettingsFile: nil,
      warning: nil
    )
  }

  /// Copilot needs no merge: every `--plugin-dir` loads additively, so Prowl appends its
  /// bundled plugin and leaves the user's plugins and hook files untouched.
  private static func prepareCopilot(
    plan: AgentProfileLaunchPlan,
    capability: AgentSignalHookCapability,
    inheritedCWD: URL,
    resources: AgentHookResources,
    promptIndex: Int?
  ) -> AgentManagedHookPreparation {
    guard let pluginPath = resources.copilotPluginPath,
      pluginPath.hasPrefix("/"),
      FileManager.default.fileExists(atPath: pluginPath + "/hooks.json")
    else {
      return degraded(
        plan: plan,
        capability: capability,
        launchCWD: inheritedCWD,
        message: "The bundled Copilot hook plugin is unavailable."
      )
    }
    guard
      let launchCWD = ManagedHookWorkingDirectory.effective(
        inherited: inheritedCWD,
        scan: ManagedHookWorkingDirectory.scan(
          arguments: plan.invocation.arguments,
          optionNames: ["-C"],
          precedence: .lastWins,
          promptArgumentIndex: promptIndex
        )
      )
    else {
      return degraded(
        plan: plan,
        capability: capability,
        launchCWD: inheritedCWD,
        message: "The Copilot working directory option could not be resolved."
      )
    }
    return AgentManagedHookPreparation(
      preparedInvocation: CopilotHookPluginRenderer.prepare(
        invocation: plan.invocation,
        pluginDirectory: URL(filePath: pluginPath, directoryHint: .isDirectory),
        promptArgumentIndex: promptIndex
      ),
      capability: capability,
      launchCWD: launchCWD,
      forwardingArgv: nil,
      pendingSettingsFile: nil,
      warning: nil
    )
  }

  private struct DroidEnvironmentSettings {
    var path: String?
    var resolutionFailed = false
  }

  /// Resolve the effective `FACTORY_RUNTIME_SETTINGS_PATH` for Droid, whose managed `--settings`
  /// flag outranks it: a Profile override wins outright; otherwise the login shell is probed so a
  /// value exported in an rc file is still honored. The probe is skipped when a `--settings` flag
  /// is present (it wins anyway) or an override already answers the question. A probe that cannot
  /// run leaves the presence unknown, so the caller degrades rather than override.
  private static func resolveDroidEnvironmentSettings(
    plan: AgentProfileLaunchPlan,
    inheritedCWD: URL,
    promptIndex: Int?,
    resolver: DroidSettingsEnvironmentResolver?
  ) async -> DroidEnvironmentSettings {
    // Droid treats a blank value as unset, so a Profile override matches the shell probe here
    // (which already maps empty to unset). A non-empty path is tilde-expanded when the merge reads
    // it, so both sources name the same file the runtime would.
    func normalized(_ raw: String?) -> String? {
      guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
      }
      return value
    }
    if let override = plan.profileEnvironmentOverrides[DroidSettingsEnvironmentProbe.variableName] {
      return DroidEnvironmentSettings(path: normalized(override))
    }
    let flagPresent =
      ManagedHookSettings.scanSettings(
        arguments: plan.invocation.arguments,
        optionName: ManagedHookSettings.settingsOptionName,
        precedence: .lastWins,
        promptArgumentIndex: promptIndex
      ) != .none
    guard !flagPresent, let resolver else { return DroidEnvironmentSettings() }
    switch await resolver(inheritedCWD, plan.profileEnvironmentOverrides["PATH"]) {
    case .value(let path): return DroidEnvironmentSettings(path: normalized(path))
    case .failed: return DroidEnvironmentSettings(resolutionFailed: true)
    }
  }

  /// Droid and Qoder both configure hooks through a settings object, but with opposite
  /// precedence, and only Qoder accepts it inline. Droid's merged object therefore has to be
  /// written to an owner-only file, which may hold user secrets.
  private static func prepareSettingsRuntime(
    plan: AgentProfileLaunchPlan,
    capability: AgentSignalHookCapability,
    inheritedCWD: URL,
    resources: AgentHookResources,
    options: SettingsRuntimeOptions
  ) async -> AgentManagedHookPreparation {
    let hookCommands = shellHookCommands(capability: capability, resources: resources)
    let invocation = plan.invocation
    let runtime = capability.runtime
    let promptIndex = options.promptIndex
    // The hooks report the directory the runtime changes into; the settings path is still
    // relative to where it was launched (both measured on Droid 0.203 and Qoder 1.1.29).
    let workingDirectoryScan = ManagedHookWorkingDirectory.scan(
      arguments: invocation.arguments,
      optionNames: runtime == .qoder ? ["-w", "--cwd"] : ["--cwd"],
      precedence: runtime == .qoder ? .firstWins : .lastWins,
      promptArgumentIndex: promptIndex
    )
    guard
      let launchCWD = ManagedHookWorkingDirectory.effective(
        inherited: inheritedCWD,
        scan: workingDirectoryScan
      )
    else {
      return degraded(
        plan: plan,
        capability: capability,
        launchCWD: inheritedCWD,
        message: "The \(runtime.rawValue) working directory option could not be resolved."
      )
    }
    let environment =
      runtime == .droid
      ? await resolveDroidEnvironmentSettings(
        plan: plan, inheritedCWD: inheritedCWD, promptIndex: promptIndex,
        resolver: options.droidSettingsEnvironmentResolver)
      : DroidEnvironmentSettings()
    let settingsReadFile = options.settingsReadFile

    return await Task.detached(priority: .userInitiated) {
      let readFile: (URL, Int) -> ClaudeSettingsReadResult =
        settingsReadFile ?? { ClaudeSettingsStableReader.read($0, maximumBytes: $1) }
      switch runtime {
      case .qoder:
        let outcome = QoderHookSettingsPreparer.prepare(
          invocation: invocation,
          launchDirectory: inheritedCWD,
          promptArgumentIndex: promptIndex,
          hookCommands: hookCommands,
          readFile: readFile
        )
        return AgentManagedHookPreparation(
          preparedInvocation: outcome.prepared,
          capability: capability,
          launchCWD: launchCWD,
          forwardingArgv: nil,
          pendingSettingsFile: nil,
          warning: outcome.warning
        )
      case .droid:
        let merged = DroidHookSettingsPreparer.mergedSettings(
          invocation: invocation,
          launchDirectory: inheritedCWD,
          promptArgumentIndex: promptIndex,
          hookCommands: hookCommands,
          // `FACTORY_RUNTIME_SETTINGS_PATH` (Profile override or shell-resolved) is a settings
          // source the managed `--settings` flag would otherwise override; merge it as the base.
          environmentSettingsPath: environment.path,
          environmentResolutionFailed: environment.resolutionFailed,
          readFile: readFile
        )
        return AgentManagedHookPreparation(
          preparedInvocation: nil,
          capability: capability,
          launchCWD: launchCWD,
          forwardingArgv: nil,
          pendingSettingsFile: merged.data.map {
            PendingManagedHookSettingsFile(
              data: $0,
              invocation: invocation,
              promptArgumentIndex: promptIndex
            )
          },
          warning: merged.warning
        )
      case .claude, .codex, .copilot, .pi, .omp, .opencode:
        return AgentManagedHookPreparation(
          preparedInvocation: nil,
          capability: capability,
          launchCWD: launchCWD,
          forwardingArgv: nil,
          pendingSettingsFile: nil,
          warning: LifecycleCommandWarning(
            code: .managedHookDegraded,
            runtime: runtime.rawValue,
            message: "Managed hooks could not be prepared for this runtime."
          )
        )
      }
    }.value
  }

  /// One shell-quoted hook command per declared native event.
  private static func shellHookCommands(
    capability: AgentSignalHookCapability,
    resources: AgentHookResources
  ) -> [String: String] {
    var commands: [String: String] = [:]
    for event in capability.nativeEvents.keys.sorted() {
      commands[event] = [
        AgentInvocation.shellQuote(resources.bundledCLIPath),
        "agents",
        "_hook",
        capability.runtime.rawValue,
        event,
      ].joined(separator: " ")
    }
    return commands
  }

  private static func prepareClaude(
    plan: AgentProfileLaunchPlan,
    capability: AgentSignalHookCapability,
    inheritedCWD: URL,
    resources: AgentHookResources,
    promptIndex: Int?
  ) async -> AgentManagedHookPreparation {
    var hookCommands: [String: String] = [:]
    for event in capability.nativeEvents.keys.sorted() {
      hookCommands[event] = [
        AgentInvocation.shellQuote(resources.bundledCLIPath),
        "agents",
        "_hook",
        AgentNativeHookRuntime.claude.rawValue,
        event,
      ].joined(separator: " ")
    }
    let outcome = await Task.detached(priority: .userInitiated) {
      ClaudeHookSettingsPreparer.prepare(
        invocation: plan.invocation,
        launchDirectory: inheritedCWD,
        promptArgumentIndex: promptIndex,
        hookCommands: hookCommands,
        readFile: { ClaudeSettingsStableReader.read($0, maximumBytes: $1) }
      )
    }.value
    return AgentManagedHookPreparation(
      preparedInvocation: outcome.prepared,
      capability: capability,
      launchCWD: inheritedCWD,
      forwardingArgv: nil,
      pendingSettingsFile: nil,
      warning: outcome.warning
    )
  }

  private static func prepareCodex(
    plan: AgentProfileLaunchPlan,
    capability: AgentSignalHookCapability,
    inheritedCWD: URL,
    resources: AgentHookResources,
    options: CodexPreparationOptions
  ) async -> AgentManagedHookPreparation {
    guard let shellEnvironment = options.shellEnvironment else {
      return degraded(
        plan: plan,
        capability: capability,
        launchCWD: inheritedCWD,
        message: "The effective Codex shell environment could not be resolved."
      )
    }
    let invocation = AgentInvocation(
      executable: shellEnvironment.executableURL.path(percentEncoded: false),
      arguments: plan.invocation.arguments
    )
    let context: CodexLaunchContext
    do {
      context = try CodexLaunchContext.capture(
        invocation: invocation,
        inheritedCWD: inheritedCWD,
        dedicatedHome: plan.dedicatedHome,
        environment: shellEnvironment.processEnvironment,
        promptArgumentIndex: options.promptIndex
      )
    } catch {
      return degraded(
        plan: plan,
        capability: capability,
        launchCWD: inheritedCWD,
        message: "The effective Codex launch context could not be resolved."
      )
    }
    let resolver = CodexEffectiveNotifyResolver(
      bundledCLIPath: resources.bundledCLIPath,
      query: options.configReadProcess.usingExecutable(shellEnvironment.executableURL).query
    )
    switch await resolver.resolve(context) {
    case .absent:
      return preparedCodex(
        invocation: invocation,
        capability: capability,
        context: context,
        resources: resources,
        options: CodexRenderingOptions(
          promptIndex: options.promptIndex,
          forwardingArgv: nil
        )
      )
    case .present(let argv):
      return preparedCodex(
        invocation: invocation,
        capability: capability,
        context: context,
        resources: resources,
        options: CodexRenderingOptions(
          promptIndex: options.promptIndex,
          forwardingArgv: argv
        )
      )
    case .degraded(let message):
      return degraded(
        plan: plan,
        capability: capability,
        launchCWD: context.effectiveCWD,
        message: message
      )
    }
  }

  private static func preparedCodex(
    invocation: AgentInvocation,
    capability: AgentSignalHookCapability,
    context: CodexLaunchContext,
    resources: AgentHookResources,
    options: CodexRenderingOptions
  ) -> AgentManagedHookPreparation {
    AgentManagedHookPreparation(
      preparedInvocation: CodexManagedNotifyRenderer.prepare(
        invocation: invocation,
        bundledCLIPath: resources.bundledCLIPath,
        promptArgumentIndex: options.promptIndex
      ),
      capability: capability,
      launchCWD: context.effectiveCWD,
      forwardingArgv: options.forwardingArgv,
      pendingSettingsFile: nil,
      warning: nil
    )
  }

  private static func degraded(
    plan: AgentProfileLaunchPlan,
    capability: AgentSignalHookCapability,
    launchCWD: URL,
    message: String
  ) -> AgentManagedHookPreparation {
    AgentManagedHookPreparation(
      preparedInvocation: nil,
      capability: capability,
      launchCWD: launchCWD,
      forwardingArgv: nil,
      pendingSettingsFile: nil,
      warning: LifecycleCommandWarning(
        code: .managedHookDegraded,
        runtime: plan.runtime.rawValue,
        message: message
      )
    )
  }
}
