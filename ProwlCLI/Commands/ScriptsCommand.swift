import ArgumentParser
import Foundation
import ProwlCLIShared

struct ScriptsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "scripts",
    abstract: "Manage local workspace script profiles.",
    subcommands: [
      ScriptsListCommand.self,
      ScriptsAddCommand.self,
      ScriptsUpdateCommand.self,
      ScriptsDeleteCommand.self,
    ]
  )
}

struct ScriptProfile: Codable, Equatable {
  static let scriptEnvironmentKey = "PROWL_SCRIPT"
  static let defaultCommand = #"/bin/sh "$PROWL_SCRIPT""#

  var id: String
  var name: String
  var description: String
  var command: String
  var environment: [String: String]
  var script: String
  var timeoutSeconds: Int

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case description
    case command
    case environment
    case shell
    case script
    case timeoutSeconds = "timeout_seconds"
  }

  init(
    id: String,
    name: String,
    description: String = "",
    command: String = ScriptProfile.defaultCommand,
    environment: [String: String] = [:],
    script: String,
    timeoutSeconds: Int = 300
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.command = command
    self.environment = environment
    self.script = script
    self.timeoutSeconds = timeoutSeconds
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    let command = try container.decodeIfPresent(String.self, forKey: .command)
    let shell = try container.decodeIfPresent(String.self, forKey: .shell)
    self.command = Self.normalizedCommand(command) ?? Self.legacyCommand(for: shell) ?? Self.defaultCommand
    environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
    script = try container.decodeIfPresent(String.self, forKey: .script) ?? ""
    timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 300
  }

  func encode(to encoder: Encoder) throws {
    let normalized = normalized
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(normalized.id, forKey: .id)
    try container.encode(normalized.name, forKey: .name)
    try container.encode(normalized.description, forKey: .description)
    try container.encode(normalized.command, forKey: .command)
    if !normalized.environment.isEmpty {
      try container.encode(normalized.environment, forKey: .environment)
    }
    try container.encode(normalized.script, forKey: .script)
    try container.encode(normalized.timeoutSeconds, forKey: .timeoutSeconds)
  }

  var normalized: ScriptProfile {
    ScriptProfile(
      id: id.trimmingCharacters(in: .whitespacesAndNewlines),
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      description: description.trimmingCharacters(in: .whitespacesAndNewlines),
      command: Self.normalizedCommand(command) ?? Self.defaultCommand,
      environment: Self.normalizedEnvironment(environment),
      script: script,
      timeoutSeconds: max(1, timeoutSeconds)
    )
  }

  private static func legacyCommand(for shell: String?) -> String? {
    guard let shell = trimmedNonEmpty(shell) else {
      return nil
    }
    return #"\#(shell) "$\#(scriptEnvironmentKey)""#
  }

  private static func normalizedCommand(_ value: String?) -> String? {
    guard let command = trimmedNonEmpty(value) else {
      return nil
    }
    return command.replacing("$script", with: "$\(scriptEnvironmentKey)")
  }

  private static func normalizedEnvironment(_ environment: [String: String]) -> [String: String] {
    var result: [String: String] = [:]
    for (key, value) in environment {
      let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedKey.isEmpty else {
        continue
      }
      result[trimmedKey] = value
    }
    return result
  }

  private static func trimmedNonEmpty(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  var payload: ScriptProfilePayloadModel {
    let normalized = normalized
    return ScriptProfilePayloadModel(
      id: normalized.id,
      name: normalized.name,
      description: normalized.description,
      command: normalized.command,
      environment: normalized.environment,
      script: normalized.script,
      timeoutSeconds: normalized.timeoutSeconds
    )
  }
}

struct ScriptProfileStore {
  var url: URL

  func load() throws -> [ScriptProfile] {
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
      return []
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode([ScriptProfile].self, from: data).map(\.normalized)
  }

  func save(_ profiles: [ScriptProfile]) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let normalized = normalizedProfiles(profiles)
    let data = try encoder.encode(normalized)
    try data.write(to: url, options: .atomic)
  }

  private func normalizedProfiles(_ profiles: [ScriptProfile]) -> [ScriptProfile] {
    var seen = Set<String>()
    var result: [ScriptProfile] = []
    for profile in profiles {
      let normalized = profile.normalized
      guard !normalized.id.isEmpty, seen.insert(normalized.id).inserted else {
        continue
      }
      result.append(normalized)
    }
    return result
  }
}

struct ScriptOptions: ParsableArguments {
  @OptionGroup var options: GlobalOptions

  @Option(name: .long, help: "Path to script-profiles.json. Defaults to ~/.prowl/script-profiles.json.")
  var file: String?

  var store: ScriptProfileStore {
    ScriptProfileStore(url: URL(fileURLWithPath: file ?? defaultScriptProfilesPath()))
  }
}

struct ScriptsListCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "list", abstract: "List script profiles.")

  @OptionGroup var scriptOptions: ScriptOptions

  mutating func run() throws {
    let outputMode = scriptOptions.options.outputMode
    try CLIExecution.run(command: "scripts", output: outputMode, colorEnabled: scriptOptions.options.colorEnabled)
    {
      let store = scriptOptions.store
      let profiles = try store.load()
      let payload = ScriptProfilesPayload(
        path: store.url.path(percentEncoded: false),
        profiles: profiles.map(\.payload)
      )
      try render(payload, output: outputMode)
    }
  }
}

struct ScriptsAddCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a script profile.")

  @OptionGroup var scriptOptions: ScriptOptions

  @Option(name: .long, help: "Stable profile id.")
  var id: String

  @Option(name: .long, help: "Display name. Defaults to the id.")
  var name: String?

  @Option(name: .long, help: "Description.")
  var description: String = ""

  @Option(name: .long, help: "Command used to run the script. Use $PROWL_SCRIPT for the script path.")
  var command: String = ScriptProfile.defaultCommand

  @Option(name: .long, help: "Environment variable in KEY=VALUE form. Can be repeated.")
  var env: [String] = []

  @Option(name: .long, help: "Script text. If omitted, --script-file or stdin is used.")
  var script: String?

  @Option(name: .long, help: "Path to a script file.")
  var scriptFile: String?

  @Option(name: .long, help: "Timeout in seconds.")
  var timeout: Int = 300

  mutating func run() throws {
    let outputMode = scriptOptions.options.outputMode
    try CLIExecution.run(command: "scripts", output: outputMode, colorEnabled: scriptOptions.options.colorEnabled)
    {
      let store = scriptOptions.store
      var profiles = try store.load()
      let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalizedID.isEmpty else {
        throw ExitError(code: CLIErrorCode.invalidArgument, message: "Profile id is required.")
      }
      guard !profiles.contains(where: { $0.id == normalizedID }) else {
        throw ExitError(
          code: CLIErrorCode.invalidArgument, message: "Script profile already exists: \(normalizedID)")
      }
      let profile = ScriptProfile(
        id: normalizedID,
        name: name ?? normalizedID,
        description: description,
        command: command,
        environment: try parseEnvironment(env),
        script: try resolveScript(script: script, scriptFile: scriptFile),
        timeoutSeconds: timeout
      ).normalized
      profiles.append(profile)
      try store.save(profiles)
      try render(
        ScriptProfilePayload(path: store.url.path(percentEncoded: false), profile: profile.payload),
        output: outputMode
      )
    }
  }
}

struct ScriptsUpdateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a script profile.")

  @OptionGroup var scriptOptions: ScriptOptions

  @Argument(help: "Profile id.")
  var id: String

  @Option(name: .long, help: "Display name.")
  var name: String?

  @Option(name: .long, help: "Description.")
  var description: String?

  @Option(name: .long, help: "Command used to run the script.")
  var command: String?

  @Option(name: .long, help: "Environment variable in KEY=VALUE form. Replaces existing env.")
  var env: [String] = []

  @Flag(name: .long, help: "Clear all custom environment variables.")
  var clearEnv = false

  @Option(name: .long, help: "Script text.")
  var script: String?

  @Option(name: .long, help: "Path to a script file.")
  var scriptFile: String?

  @Option(name: .long, help: "Timeout in seconds.")
  var timeout: Int?

  mutating func run() throws {
    let outputMode = scriptOptions.options.outputMode
    try CLIExecution.run(command: "scripts", output: outputMode, colorEnabled: scriptOptions.options.colorEnabled)
    {
      let store = scriptOptions.store
      var profiles = try store.load()
      guard let index = profiles.firstIndex(where: { $0.id == id }) else {
        throw ExitError(code: CLIErrorCode.targetNotFound, message: "Script profile not found: \(id)")
      }
      var profile = profiles[index]
      if let name {
        profile.name = name
      }
      if let description {
        profile.description = description
      }
      if let command {
        profile.command = command
      }
      if clearEnv {
        profile.environment = [:]
      }
      if !env.isEmpty {
        profile.environment = try parseEnvironment(env)
      }
      if script != nil || scriptFile != nil {
        profile.script = try resolveScript(script: script, scriptFile: scriptFile)
      }
      if let timeout {
        profile.timeoutSeconds = timeout
      }
      profile = profile.normalized
      profiles[index] = profile
      try store.save(profiles)
      try render(
        ScriptProfilePayload(path: store.url.path(percentEncoded: false), profile: profile.payload),
        output: outputMode
      )
    }
  }
}

struct ScriptsDeleteCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a script profile.")

  @OptionGroup var scriptOptions: ScriptOptions

  @Argument(help: "Profile id.")
  var id: String

  mutating func run() throws {
    let outputMode = scriptOptions.options.outputMode
    try CLIExecution.run(command: "scripts", output: outputMode, colorEnabled: scriptOptions.options.colorEnabled)
    {
      let store = scriptOptions.store
      var profiles = try store.load()
      guard let index = profiles.firstIndex(where: { $0.id == id }) else {
        throw ExitError(code: CLIErrorCode.targetNotFound, message: "Script profile not found: \(id)")
      }
      profiles.remove(at: index)
      try store.save(profiles)
      try render(ScriptDeletePayload(path: store.url.path(percentEncoded: false), id: id), output: outputMode)
    }
  }
}

private func render<T: Encodable>(_ payload: T, output: OutputMode) throws {
  let response = try CommandResponse(
    ok: true,
    command: "scripts",
    schemaVersion: "prowl.cli.scripts.v1",
    data: RawJSON(encoding: payload)
  )
  OutputRenderer.render(response, mode: output)
}

private func parseEnvironment(_ values: [String]) throws -> [String: String] {
  var result: [String: String] = [:]
  for value in values {
    guard let separator = value.firstIndex(of: "=") else {
      throw ExitError(code: CLIErrorCode.invalidArgument, message: "Environment must use KEY=VALUE: \(value)")
    }
    let key = String(value[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      throw ExitError(code: CLIErrorCode.invalidArgument, message: "Environment key is required.")
    }
    result[key] = String(value[value.index(after: separator)...])
  }
  return result
}

private func resolveScript(script: String?, scriptFile: String?) throws -> String {
  if script != nil, scriptFile != nil {
    throw ExitError(code: CLIErrorCode.invalidArgument, message: "Use either --script or --script-file, not both.")
  }
  if let script {
    return script
  }
  if let scriptFile {
    return try String(contentsOf: URL(fileURLWithPath: scriptFile), encoding: .utf8)
  }
  let data = FileHandle.standardInput.readDataToEndOfFile()
  if !data.isEmpty, let input = String(data: data, encoding: .utf8) {
    return input
  }
  throw ExitError(code: CLIErrorCode.invalidArgument, message: "Script is required.")
}

private func defaultScriptProfilesPath() -> String {
  FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".prowl", directoryHint: .isDirectory)
    .appending(path: "script-profiles.json", directoryHint: .notDirectory)
    .path(percentEncoded: false)
}
