import Foundation
import ProwlCLIShared

nonisolated enum ClaudeSettingsReadResult: Equatable, Sendable {
  case stable(Data)
  case changed
  case oversized
  case unreadable
}

nonisolated enum ClaudeSettingsStableReader {
  static func read(
    _ url: URL,
    maximumBytes: Int,
    afterRead: () -> Void = {}
  ) -> ClaudeSettingsReadResult {
    switch StableOwnerFileReader.read(url, maximumBytes: maximumBytes, afterRead: afterRead) {
    case .stable(let data): .stable(data)
    case .changed: .changed
    case .oversized: .oversized
    case .unreadable: .unreadable
    }
  }
}

/// JSON settings hook merging shared by every runtime whose hook configuration is a settings
/// object: Claude (`--settings`, last-wins, inline or path), Qoder (`--settings`, first-wins,
/// inline or path), and Droid (`--settings`, last-wins, path only).
nonisolated enum ManagedHookSettings {
  static let maximumBytes = 256 * 1_024

  /// Decode an inline-JSON-or-path settings source into an object, or fail closed.
  static func object(
    from source: String,
    launchDirectory: URL,
    allowInline: Bool = true,
    readFile: (URL, Int) -> ClaudeSettingsReadResult
  ) -> [String: Any]? {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    let data: Data
    if allowInline, trimmed.hasPrefix("{") {
      data = Data(trimmed.utf8)
      guard data.count <= maximumBytes else { return nil }
    } else {
      // A path-only source (Droid) is trimmed and tilde-expanded the way the runtime resolves it,
      // so `~/settings.json` or a value with stray whitespace names the same file Droid would read.
      let pathValue = allowInline ? source : (trimmed as NSString).expandingTildeInPath
      let sourceURL = URL(filePath: pathValue, relativeTo: launchDirectory).standardizedFileURL
      switch readFile(sourceURL, maximumBytes) {
      case .stable(let value): data = value
      case .changed, .oversized, .unreadable: return nil
      }
    }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  /// Append Prowl's command hooks while preserving unknown fields and every existing handler.
  /// Returns `nil` when the object's `hooks` shape is not one this merge understands.
  static func merged(_ object: [String: Any], hookCommands: [String: String]) -> [String: Any]? {
    var object = object
    var hooks: [String: Any]
    if let existing = object["hooks"] {
      guard let existing = existing as? [String: Any] else { return nil }
      hooks = existing
    } else {
      hooks = [:]
    }

    for event in hookCommands.keys.sorted() {
      guard let command = hookCommands[event] else { continue }
      var matchers: [[String: Any]]
      if let existing = hooks[event] {
        guard let existing = existing as? [[String: Any]] else { return nil }
        matchers = existing
      } else {
        matchers = []
      }
      if !containsCommand(command, in: matchers) {
        matchers.append(["hooks": [["command": command, "type": "command"]]])
      }
      hooks[event] = matchers
    }
    object["hooks"] = hooks
    return object
  }

  static func serializedData(_ object: [String: Any]) -> Data? {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
      ),
      data.count <= maximumBytes
    else { return nil }
    return data
  }

  static func serialized(_ object: [String: Any]) -> String? {
    serializedData(object).flatMap { String(data: $0, encoding: .utf8) }
  }

  /// Managed options are inserted before the runtime's prompt argument and before any
  /// end-of-options sentinel, so they are always parsed as options.
  static func insertionIndex(promptArgumentIndex: Int?, arguments: [String]) -> Int {
    let promptIndex =
      promptArgumentIndex.flatMap { arguments.indices.contains($0) ? $0 : nil } ?? arguments.endIndex
    let sentinelIndex = arguments.firstIndex(of: "--") ?? arguments.endIndex
    return min(promptIndex, sentinelIndex)
  }

  static func degraded(
    _ invocation: AgentInvocation,
    runtime: AgentNativeHookRuntime,
    message: String
  ) -> AgentHookPreparationOutcome {
    AgentHookPreparationOutcome(
      originalInvocation: invocation,
      prepared: nil,
      warning: LifecycleCommandWarning(
        code: .managedHookDegraded,
        runtime: runtime.rawValue,
        message: message
      )
    )
  }

  private static func containsCommand(_ command: String, in matchers: [[String: Any]]) -> Bool {
    matchers.contains { matcher in
      guard let handlers = matcher["hooks"] as? [[String: Any]] else { return false }
      return handlers.contains {
        ($0["type"] as? String) == "command" && ($0["command"] as? String) == command
      }
    }
  }
}

nonisolated extension ManagedHookSettings {
  /// Which repeated occurrence of a settings option the runtime actually honors.
  enum Precedence: Sendable {
    case firstWins
    case lastWins
  }

  enum SettingsScan: Equatable {
    case none
    case source(String)
    case malformed
  }

  /// Find the settings source the runtime will honor. `--option value` and `--option=value`
  /// are both recognized; the prompt argument is skipped so it can never be read as a value.
  static func scanSettings(
    arguments: [String],
    optionName: String,
    precedence: Precedence,
    promptArgumentIndex: Int?
  ) -> SettingsScan {
    let joinedPrefix = "\(optionName)="
    var found: String?
    var index = 0
    while index < arguments.count {
      if index == promptArgumentIndex {
        index += 1
        continue
      }
      let argument = arguments[index]
      if argument == "--" { break }
      if argument == optionName {
        guard arguments.indices.contains(index + 1), index + 1 != promptArgumentIndex else {
          return .malformed
        }
        if found == nil || precedence == .lastWins { found = arguments[index + 1] }
        index += 2
        continue
      }
      if argument.hasPrefix(joinedPrefix) {
        let value = String(argument.dropFirst(joinedPrefix.count))
        if found == nil || precedence == .lastWins { found = value }
      }
      index += 1
    }
    return found.map(SettingsScan.source) ?? .none
  }

  enum EffectiveSettings {
    /// The object the runtime would load: empty when the user supplied no source.
    case object([String: Any])
    /// A source exists but cannot be used. Injecting anyway would drop the user's config,
    /// so the launch must degrade instead.
    case unusable
  }

  /// Every settings-based runtime uses the same option name; only precedence differs.
  static let settingsOptionName = "--settings"

  static func effectiveObject(
    arguments: [String],
    precedence: Precedence,
    promptArgumentIndex: Int?,
    launchDirectory: URL,
    allowInline: Bool = true,
    readFile: (URL, Int) -> ClaudeSettingsReadResult
  ) -> EffectiveSettings {
    switch scanSettings(
      arguments: arguments,
      optionName: settingsOptionName,
      precedence: precedence,
      promptArgumentIndex: promptArgumentIndex
    ) {
    case .none:
      return .object([:])
    case .malformed:
      return .unusable
    case .source(let value):
      guard
        let object = object(
          from: value, launchDirectory: launchDirectory, allowInline: allowInline, readFile: readFile)
      else { return .unusable }
      return .object(object)
    }
  }
}

/// The working directory a runtime will actually report in its hook payloads. Copilot (`-C`,
/// last wins), Droid (`--cwd`, last wins), and Qoder (`-w`/`--cwd`, first wins) all change
/// directory before their hooks run, while a relative `--settings` path is still resolved
/// against the directory they were launched from — both measured, so the two must stay apart.
nonisolated enum ManagedHookWorkingDirectory {
  enum Scan: Equatable, Sendable {
    case inherited
    case changed(String)
    case malformed
  }

  /// `--option value` and `--option=value` are recognized for long options, `-X value` and
  /// `-Xvalue` for single-letter ones. The prompt argument is never read as a value.
  static func scan(
    arguments: [String],
    optionNames: [String],
    precedence: ManagedHookSettings.Precedence,
    promptArgumentIndex: Int?
  ) -> Scan {
    var found: String?
    var index = 0
    func record(_ value: String) {
      if found == nil || precedence == .lastWins { found = value }
    }
    while index < arguments.count {
      if index == promptArgumentIndex {
        index += 1
        continue
      }
      let argument = arguments[index]
      if argument == "--" { break }
      if optionNames.contains(argument) {
        guard arguments.indices.contains(index + 1), index + 1 != promptArgumentIndex else {
          return .malformed
        }
        record(arguments[index + 1])
        index += 2
        continue
      }
      for name in optionNames {
        let isLong = name.hasPrefix("--")
        let joinedPrefix = isLong ? "\(name)=" : name
        guard argument.hasPrefix(joinedPrefix), argument.count > joinedPrefix.count else { continue }
        record(String(argument.dropFirst(joinedPrefix.count)))
        break
      }
      index += 1
    }
    return found.map(Scan.changed) ?? .inherited
  }

  /// Resolve a scan against the launch directory; `nil` means the option could not be read,
  /// so the launch must degrade rather than register a directory the hooks will never report.
  static func effective(inherited: URL, scan: Scan) -> URL? {
    switch scan {
    case .inherited:
      return inherited
    case .changed(let value):
      return URL(filePath: value, directoryHint: .isDirectory, relativeTo: inherited).standardizedFileURL
    case .malformed:
      return nil
    }
  }
}

/// Copilot loads every `--plugin-dir` additively, so Prowl appends its own bundled plugin and
/// never merges with, replaces, or inspects the user's plugins or `~/.copilot/hooks/*.json`.
nonisolated enum CopilotHookPluginRenderer {
  /// Copilot passes a prompted start as the value of `--interactive` / `--prompt`, so managed
  /// options must land before that option rather than between the option and its value.
  static func prepare(
    invocation: AgentInvocation,
    pluginDirectory: URL,
    promptArgumentIndex: Int?
  ) -> AgentHookPreparedInvocation {
    var arguments = invocation.arguments
    let insertionIndex = ManagedHookSettings.insertionIndex(
      promptArgumentIndex: promptArgumentIndex.map { max(0, $0 - 1) },
      arguments: arguments
    )
    arguments.insert(contentsOf: ["--plugin-dir", ""], at: insertionIndex)
    return AgentHookPreparedInvocation(
      invocation: AgentInvocation(executable: invocation.executable, arguments: arguments),
      argumentValues: [insertionIndex + 1: pluginDirectory.path(percentEncoded: false)]
    )
  }
}

/// Qoder honors the *first* `--settings`, so a merged object is inserted ahead of the user's.
/// Inserting after would leave Prowl's hooks dead; inserting an unmerged object ahead would
/// silently disable the user's settings.
nonisolated enum QoderHookSettingsPreparer {
  static func prepare(
    invocation: AgentInvocation,
    launchDirectory: URL,
    promptArgumentIndex: Int?,
    hookCommands: [String: String],
    readFile: (URL, Int) -> ClaudeSettingsReadResult
  ) -> AgentHookPreparationOutcome {
    // `--setting-sources` drops flag-supplied hooks entirely, so injecting would only create
    // a channel that never fires.
    if containsSettingSources(invocation.arguments, promptArgumentIndex: promptArgumentIndex) {
      return ManagedHookSettings.degraded(
        invocation,
        runtime: .qoder,
        message: "Managed Qoder hooks are unavailable when --setting-sources is set; launching unchanged."
      )
    }

    guard
      case .object(let base) = ManagedHookSettings.effectiveObject(
        arguments: invocation.arguments,
        precedence: .firstWins,
        promptArgumentIndex: promptArgumentIndex,
        launchDirectory: launchDirectory,
        readFile: readFile
      ),
      let merged = ManagedHookSettings.merged(base, hookCommands: hookCommands),
      let json = ManagedHookSettings.serialized(merged)
    else {
      return ManagedHookSettings.degraded(
        invocation,
        runtime: .qoder,
        message: "Managed Qoder hooks could not be prepared; launching with the original settings."
      )
    }

    var arguments = invocation.arguments
    arguments.insert(contentsOf: ["--settings", ""], at: 0)
    return AgentHookPreparationOutcome(
      originalInvocation: invocation,
      prepared: AgentHookPreparedInvocation(
        invocation: AgentInvocation(executable: invocation.executable, arguments: arguments),
        argumentValues: [1: json]
      ),
      warning: nil
    )
  }

  private static func containsSettingSources(
    _ arguments: [String],
    promptArgumentIndex: Int?
  ) -> Bool {
    for (index, argument) in arguments.enumerated() {
      if index == promptArgumentIndex { continue }
      if argument == "--" { return false }
      if argument == "--setting-sources" || argument.hasPrefix("--setting-sources=") { return true }
    }
    return false
  }
}

/// Droid's `--settings` accepts a path only, so the merged object must be written to an
/// owner-only file: a user's settings can carry secrets such as `customModels[].apiKey`.
/// Repeated flags are last-wins, so Prowl's path is appended after the user's.
nonisolated enum DroidHookSettingsPreparer {
  struct MergedSettings: Equatable, Sendable {
    let data: Data?
    let warning: LifecycleCommandWarning?
  }

  /// Phase 1, pure: resolve the effective user settings and merge Prowl's handlers in.
  /// Writing is the caller's job because the owner-only store is main-actor isolated.
  static func mergedSettings(
    invocation: AgentInvocation,
    launchDirectory: URL,
    promptArgumentIndex: Int?,
    hookCommands: [String: String],
    environmentSettingsPath: String? = nil,
    environmentResolutionFailed: Bool = false,
    readFile: (URL, Int) -> ClaudeSettingsReadResult
  ) -> MergedSettings {
    func degraded() -> MergedSettings {
      MergedSettings(
        data: nil,
        warning: LifecycleCommandWarning(
          code: .managedHookDegraded,
          runtime: AgentNativeHookRuntime.droid.rawValue,
          message: "Managed Droid hooks could not be prepared; launching with the original settings."
        )
      )
    }

    // The `--settings` flag wins over `FACTORY_RUNTIME_SETTINGS_PATH` (measured), so resolve the
    // base the runtime would load: the flag if present, otherwise the env-pointed file. Injecting
    // the managed flag without merging the env file would silently drop the user's config, so an
    // unreadable env source degrades rather than overrides. Droid's `--settings` is path-only, so
    // a `{`-prefixed value is a missing path, never inline JSON to synthesize.
    let base: [String: Any]
    switch ManagedHookSettings.effectiveObject(
      arguments: invocation.arguments,
      precedence: .lastWins,
      promptArgumentIndex: promptArgumentIndex,
      launchDirectory: launchDirectory,
      allowInline: false,
      readFile: readFile
    ) {
    case .unusable:
      return degraded()
    case .object(let flagBase) where !flagBase.isEmpty:
      base = flagBase
    case .object:
      if ManagedHookSettings.scanSettings(
        arguments: invocation.arguments,
        optionName: ManagedHookSettings.settingsOptionName,
        precedence: .lastWins,
        promptArgumentIndex: promptArgumentIndex
      ) != .none {
        base = [:]  // an explicit empty `{}` flag object: honor it as-is
      } else if let environmentSettingsPath {
        guard
          let object = ManagedHookSettings.object(
            from: environmentSettingsPath,
            launchDirectory: launchDirectory,
            allowInline: false,
            readFile: readFile
          )
        else { return degraded() }
        base = object
      } else if environmentResolutionFailed {
        // The shell could not be consulted, so `FACTORY_RUNTIME_SETTINGS_PATH` might point at a
        // config the injected flag would override. Degrade rather than risk dropping it.
        return degraded()
      } else {
        base = [:]
      }
    }

    guard
      let merged = ManagedHookSettings.merged(base, hookCommands: hookCommands),
      let data = ManagedHookSettings.serializedData(merged),
      // The merged object is written to the owner-only private-file store, whose cap is smaller
      // than the generic merge cap. Degrade here, with the Droid reason, rather than serialize
      // successfully and fail opaquely at write time.
      data.count <= CodexForwardingRecordReader.maximumRecordBytes
    else {
      return degraded()
    }
    return MergedSettings(data: data, warning: nil)
  }

  /// Phase 2: point Droid at the written file. Repeated flags are last-wins, so Prowl's path
  /// is appended after any the user supplied.
  static func applying(
    settingsPath: URL,
    invocation: AgentInvocation,
    promptArgumentIndex: Int?
  ) -> AgentHookPreparedInvocation {
    var arguments = invocation.arguments
    let insertionIndex = ManagedHookSettings.insertionIndex(
      promptArgumentIndex: promptArgumentIndex,
      arguments: arguments
    )
    arguments.insert(contentsOf: ["--settings", ""], at: insertionIndex)
    return AgentHookPreparedInvocation(
      invocation: AgentInvocation(executable: invocation.executable, arguments: arguments),
      argumentValues: [insertionIndex + 1: settingsPath.path(percentEncoded: false)]
    )
  }
}

nonisolated struct AgentHookPreparedInvocation: Equatable, Sendable {
  let invocation: AgentInvocation
  /// Actual argv values carried through owner-controlled surface environment.
  /// Keys are indexes in `invocation.arguments`.
  let argumentValues: [Int: String]
  /// Launch-scoped environment variables (name -> value) that ride owner-controlled carriers
  /// exactly like `argumentValues`: the typed command names the carrier, never the value.
  let environmentValues: [String: String]

  init(
    invocation: AgentInvocation,
    argumentValues: [Int: String],
    environmentValues: [String: String] = [:]
  ) {
    self.invocation = invocation
    self.argumentValues = argumentValues
    self.environmentValues = environmentValues
  }
}

nonisolated struct AgentHookPreparationOutcome: Equatable, Sendable {
  let originalInvocation: AgentInvocation
  let prepared: AgentHookPreparedInvocation?
  let warning: LifecycleCommandWarning?
}

nonisolated enum ClaudeHookSettingsPreparer {
  static let maximumSettingsBytes = 256 * 1_024

  static func prepare(
    invocation: AgentInvocation,
    launchDirectory: URL,
    promptArgumentIndex: Int? = nil,
    hookCommands: [String: String],
    readFile: (URL, Int) -> ClaudeSettingsReadResult
  ) -> AgentHookPreparationOutcome {
    let source: SettingsSource?
    switch finalSettingsSource(
      in: invocation.arguments,
      promptArgumentIndex: promptArgumentIndex
    ) {
    case .none:
      source = nil
    case .source(let value):
      source = value
    case .malformed:
      return degraded(invocation)
    }
    let baseObject: [String: Any]
    if let source {
      switch settingsObject(
        source.value,
        launchDirectory: launchDirectory,
        readFile: readFile
      ) {
      case .success(let object):
        baseObject = object
      case .failure:
        return degraded(invocation)
      }
    } else {
      baseObject = [:]
    }

    guard let merged = mergedObject(baseObject, hookCommands: hookCommands),
      JSONSerialization.isValidJSONObject(merged),
      let data = try? JSONSerialization.data(
        withJSONObject: merged,
        options: [.sortedKeys, .withoutEscapingSlashes]
      ),
      data.count <= maximumSettingsBytes,
      let json = String(data: data, encoding: .utf8)
    else {
      return degraded(invocation)
    }

    var arguments = invocation.arguments
    let carrierIndex: Int
    if let source {
      switch source.form {
      case .separate:
        carrierIndex = source.argumentIndex
      case .joined:
        arguments[source.argumentIndex] = "--settings"
        arguments.insert("{}", at: source.argumentIndex + 1)
        carrierIndex = source.argumentIndex + 1
      }
    } else {
      let insertionIndex = managedOptionInsertionIndex(
        promptArgumentIndex: promptArgumentIndex,
        arguments: arguments
      )
      arguments.insert(contentsOf: ["--settings", "{}"], at: insertionIndex)
      carrierIndex = insertionIndex + 1
    }

    return AgentHookPreparationOutcome(
      originalInvocation: invocation,
      prepared: AgentHookPreparedInvocation(
        invocation: AgentInvocation(executable: invocation.executable, arguments: arguments),
        argumentValues: [carrierIndex: json]
      ),
      warning: nil
    )
  }

  private enum SettingsForm {
    case separate
    case joined
  }

  private enum SettingsScan {
    case none
    case source(SettingsSource)
    case malformed
  }

  private struct SettingsSource {
    let form: SettingsForm
    let argumentIndex: Int
    let value: String
  }

  private enum SettingsObjectResult {
    case success([String: Any])
    case failure
  }

  private static func finalSettingsSource(
    in arguments: [String],
    promptArgumentIndex: Int?
  ) -> SettingsScan {
    var result: SettingsSource?
    var index = 0
    while index < arguments.count {
      if index == promptArgumentIndex {
        index += 1
        continue
      }
      let argument = arguments[index]
      if argument == "--" { break }
      if argument == "--settings" {
        guard arguments.indices.contains(index + 1), index + 1 != promptArgumentIndex else {
          return .malformed
        }
        result = SettingsSource(form: .separate, argumentIndex: index + 1, value: arguments[index + 1])
        index += 2
        continue
      }
      if argument.hasPrefix("--settings=") {
        result = SettingsSource(
          form: .joined,
          argumentIndex: index,
          value: String(argument.dropFirst("--settings=".count))
        )
      }
      index += 1
    }
    return result.map(SettingsScan.source) ?? .none
  }

  private static func settingsObject(
    _ source: String,
    launchDirectory: URL,
    readFile: (URL, Int) -> ClaudeSettingsReadResult
  ) -> SettingsObjectResult {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    let data: Data
    if trimmed.hasPrefix("{") {
      data = Data(trimmed.utf8)
      guard data.count <= maximumSettingsBytes else { return .failure }
    } else {
      let sourceURL = URL(filePath: source, relativeTo: launchDirectory).standardizedFileURL
      switch readFile(sourceURL, maximumSettingsBytes) {
      case .stable(let value): data = value
      case .changed, .oversized, .unreadable: return .failure
      }
    }
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return .failure
    }
    return .success(object)
  }

  private static func mergedObject(
    _ object: [String: Any],
    hookCommands: [String: String]
  ) -> [String: Any]? {
    var object = object
    var hooks: [String: Any]
    if let existing = object["hooks"] {
      guard let existing = existing as? [String: Any] else { return nil }
      hooks = existing
    } else {
      hooks = [:]
    }

    for event in hookCommands.keys.sorted() {
      guard let command = hookCommands[event] else { continue }
      var matchers: [[String: Any]]
      if let existing = hooks[event] {
        guard let existing = existing as? [[String: Any]] else { return nil }
        matchers = existing
      } else {
        matchers = []
      }
      if !containsCommand(command, in: matchers) {
        matchers.append([
          "hooks": [
            [
              "command": command,
              "type": "command",
            ]
          ]
        ])
      }
      hooks[event] = matchers
    }
    object["hooks"] = hooks
    return object
  }

  private static func containsCommand(_ command: String, in matchers: [[String: Any]]) -> Bool {
    matchers.contains { matcher in
      guard let handlers = matcher["hooks"] as? [[String: Any]] else { return false }
      return handlers.contains {
        ($0["type"] as? String) == "command" && ($0["command"] as? String) == command
      }
    }
  }

  private static func managedOptionInsertionIndex(
    promptArgumentIndex: Int?,
    arguments: [String]
  ) -> Int {
    let promptIndex =
      promptArgumentIndex.flatMap {
        arguments.indices.contains($0) ? $0 : nil
      } ?? arguments.endIndex
    let sentinelIndex = arguments.firstIndex(of: "--") ?? arguments.endIndex
    return min(promptIndex, sentinelIndex)
  }

  private static func degraded(_ invocation: AgentInvocation) -> AgentHookPreparationOutcome {
    AgentHookPreparationOutcome(
      originalInvocation: invocation,
      prepared: nil,
      warning: LifecycleCommandWarning(
        code: .managedHookDegraded,
        runtime: AgentNativeHookRuntime.claude.rawValue,
        message: "Managed Claude hooks could not be prepared; launching with the original settings."
      )
    )
  }
}

nonisolated enum CodexManagedNotifyRenderer {
  static func prepare(
    invocation: AgentInvocation,
    bundledCLIPath: String,
    promptArgumentIndex: Int? = nil
  ) -> AgentHookPreparedInvocation {
    let notifyArgv = [
      bundledCLIPath,
      "agents",
      "_hook",
      AgentNativeHookRuntime.codex.rawValue,
      "agent-turn-complete",
    ]
    let notifyData = try? JSONSerialization.data(
      withJSONObject: notifyArgv,
      options: [.withoutEscapingSlashes]
    )
    let notifyJSON = notifyData.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    var arguments = invocation.arguments
    let promptIndex =
      promptArgumentIndex.flatMap {
        arguments.indices.contains($0) ? $0 : nil
      } ?? arguments.endIndex
    let sentinelIndex = arguments.firstIndex(of: "--") ?? arguments.endIndex
    let insertionIndex = min(promptIndex, sentinelIndex)
    arguments.insert(contentsOf: ["-c", "notify=[]"], at: insertionIndex)
    return AgentHookPreparedInvocation(
      invocation: AgentInvocation(executable: invocation.executable, arguments: arguments),
      argumentValues: [insertionIndex + 1: "notify=\(notifyJSON)"]
    )
  }
}

/// Pi (`-e`) and Oh My Pi (`--hook`) load every extension flag additively and keep explicit
/// paths even under `--no-extensions`, so Prowl appends its bundled extension file ahead of the
/// prompt positional and never inspects discovered or user-supplied extensions.
nonisolated enum ExtensionFlagHookRenderer {
  static func prepare(
    invocation: AgentInvocation,
    option: String,
    extensionPath: String,
    promptArgumentIndex: Int?
  ) -> AgentHookPreparedInvocation {
    var arguments = invocation.arguments
    let insertionIndex = ManagedHookSettings.insertionIndex(
      promptArgumentIndex: promptArgumentIndex,
      arguments: arguments
    )
    arguments.insert(contentsOf: [option, ""], at: insertionIndex)
    return AgentHookPreparedInvocation(
      invocation: AgentInvocation(executable: invocation.executable, arguments: arguments),
      argumentValues: [insertionIndex + 1: extensionPath]
    )
  }
}

/// OpenCode loads plugins from `OPENCODE_CONFIG_CONTENT`, one more config layer whose
/// `plugin[]` concatenates with the global and project lists (measured on 1.18.23), so Prowl
/// only appends its bundled plugin to whatever content the launch already carries and never
/// touches a config file. `--pure` and `OPENCODE_PURE` drop every external plugin, so those
/// launches degrade instead of registering a channel that can never fire.
nonisolated enum OpenCodeHookPluginPreparer {
  static let contentVariableName = "OPENCODE_CONFIG_CONTENT"
  static let pureVariableName = "OPENCODE_PURE"
  static let environmentVariableNames = [contentVariableName, pureVariableName]

  /// OpenCode treats the variable as set unless it is `0` or `false`; an empty value still
  /// counts (measured on 1.18.23).
  static func isPure(environmentValue: String?) -> Bool {
    guard let environmentValue else { return false }
    let normalized = environmentValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return !["0", "false"].contains(normalized)
  }

  static func containsPureFlag(_ arguments: [String], promptArgumentIndex: Int?) -> Bool {
    for (index, argument) in arguments.enumerated() where index != promptArgumentIndex {
      if argument == "--" { return false }
      if argument == "--pure" || argument == "--pure=true" { return true }
    }
    return false
  }

  static func containsAutoFlag(_ arguments: [String], promptArgumentIndex: Int?) -> Bool {
    for (index, argument) in arguments.enumerated() where index != promptArgumentIndex {
      if argument == "--" { return false }
      if argument == "--auto" || argument == "--auto=true" { return true }
    }
    return false
  }

  static func prepare(
    invocation: AgentInvocation,
    pluginPath: String,
    existingContent: String?,
    promptArgumentIndex: Int?
  ) -> AgentHookPreparationOutcome {
    if containsPureFlag(invocation.arguments, promptArgumentIndex: promptArgumentIndex) {
      return ManagedHookSettings.degraded(
        invocation,
        runtime: .opencode,
        message: "Managed OpenCode hooks are unavailable when --pure is set; launching unchanged."
      )
    }
    var object: [String: Any] = [:]
    // OpenCode ignores an empty variable, so only a non-blank value is an existing layer.
    if let existingContent, !existingContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let data = Data(existingContent.utf8)
      guard data.count <= ManagedHookSettings.maximumBytes,
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        return ManagedHookSettings.degraded(
          invocation,
          runtime: .opencode,
          message: "The existing OPENCODE_CONFIG_CONTENT is not a JSON object; launching unchanged."
        )
      }
      object = parsed
    }
    var plugins: [Any] = []
    if let existing = object["plugin"] {
      guard let list = existing as? [Any] else {
        return ManagedHookSettings.degraded(
          invocation,
          runtime: .opencode,
          message: "The existing OPENCODE_CONFIG_CONTENT plugin list is not an array; launching unchanged."
        )
      }
      plugins = list
    }
    let pluginURL = URL(filePath: pluginPath, directoryHint: .notDirectory).absoluteString
    if !plugins.contains(where: { ($0 as? String) == pluginURL }) {
      plugins.append(pluginURL)
    }
    object["plugin"] = plugins
    guard let content = ManagedHookSettings.serialized(object) else {
      return ManagedHookSettings.degraded(
        invocation,
        runtime: .opencode,
        message: "The merged OPENCODE_CONFIG_CONTENT could not be serialized; launching unchanged."
      )
    }
    return AgentHookPreparationOutcome(
      originalInvocation: invocation,
      prepared: AgentHookPreparedInvocation(
        invocation: invocation,
        argumentValues: [:],
        environmentValues: [contentVariableName: content]
      ),
      warning: nil
    )
  }
}

/// OpenCode's working directory is a positional `[project]` for the TUI and `--dir` for
/// `opencode run` (a repeated `--dir` crashes the runtime, so the last one is taken as its
/// intent); neither form has an environment equivalent.
nonisolated enum OpenCodeLaunchDirectory {
  /// Options that consume the next argument (OpenCode 1.18.23 `--help`, TUI and `run`), so a
  /// value is never mistaken for the project. The preparer additionally requires a project
  /// positional to be an existing directory, which catches a value option added later.
  private static let valueOptions: Set<String> = [
    "-m", "--model", "--agent", "--prompt", "--variant", "-s", "--session", "--port", "--hostname",
    "--mdns-domain", "--cors", "--log-level", "--replay-limit", "--dir", "--command", "-f", "--file",
    "--title", "--attach", "-p", "--password", "-u", "--username", "--format",
  ]

  static func scan(arguments: [String], promptArgumentIndex: Int?) -> ManagedHookWorkingDirectory.Scan {
    if arguments.first == "run" {
      return ManagedHookWorkingDirectory.scan(
        arguments: arguments,
        optionNames: ["--dir"],
        precedence: .lastWins,
        promptArgumentIndex: promptArgumentIndex
      )
    }
    var project: String?
    var index = 0
    while index < arguments.count {
      let current = index
      index += 1
      if current == promptArgumentIndex { continue }
      let argument = arguments[current]
      if argument == "--" { break }
      if argument.hasPrefix("-") {
        if valueOptions.contains(argument) { index += 1 }
        continue
      }
      guard project == nil else { return .malformed }
      project = argument
    }
    return project.map(ManagedHookWorkingDirectory.Scan.changed) ?? .inherited
  }
}
