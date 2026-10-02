import Foundation

nonisolated enum CodexLaunchContextError: Error, Equatable, Sendable {
  case malformedOption
  case repeatedWorkingDirectory
  case repeatedProfile
  case ignoredUserConfig
}

nonisolated private struct CodexLaunchOptionScanner {
  let arguments: [String]
  let promptArgumentIndex: Int?
  var cwdValue: String?
  var profileName: String?
  var configOverrides: [String] = []
  var explicitNotifyOverride: String?
  private var index = 0

  init(arguments: [String], promptArgumentIndex: Int?) {
    self.arguments = arguments
    self.promptArgumentIndex = promptArgumentIndex
  }

  mutating func scan() throws {
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--" { break }
      if index == promptArgumentIndex {
        index += 1
        continue
      }
      if argument == "--ignore-user-config" {
        throw CodexLaunchContextError.ignoredUserConfig
      }
      if try consumeCWD(argument) { continue }
      if try consumeProfile(argument) { continue }
      if try consumeConfigOverride(argument) { continue }
      index += 1
    }
  }

  private mutating func consumeCWD(_ argument: String) throws -> Bool {
    if argument == "-C" || argument == "--cd" {
      guard cwdValue == nil else { throw CodexLaunchContextError.repeatedWorkingDirectory }
      cwdValue = try nextValue()
      index += 2
      return true
    }
    guard argument.hasPrefix("--cd=") || (argument.hasPrefix("-C") && argument != "-C") else {
      return false
    }
    guard cwdValue == nil else { throw CodexLaunchContextError.repeatedWorkingDirectory }
    cwdValue =
      argument.hasPrefix("--cd=")
      ? String(argument.dropFirst("--cd=".count))
      : String(argument.dropFirst(2))
    index += 1
    return true
  }

  private mutating func consumeProfile(_ argument: String) throws -> Bool {
    if argument == "-p" || argument == "--profile" {
      guard profileName == nil else { throw CodexLaunchContextError.repeatedProfile }
      profileName = try nextValue()
      index += 2
      return true
    }
    guard argument.hasPrefix("--profile=") || (argument.hasPrefix("-p") && argument != "-p") else {
      return false
    }
    guard profileName == nil else { throw CodexLaunchContextError.repeatedProfile }
    profileName =
      argument.hasPrefix("--profile=")
      ? String(argument.dropFirst("--profile=".count))
      : String(argument.dropFirst(2))
    index += 1
    return true
  }

  private mutating func consumeConfigOverride(_ argument: String) throws -> Bool {
    if argument == "-c" || argument == "--config" {
      appendOverride(try nextValue())
      index += 2
      return true
    }
    guard argument.hasPrefix("--config=") || (argument.hasPrefix("-c") && argument != "-c") else {
      return false
    }
    let value =
      argument.hasPrefix("--config=")
      ? String(argument.dropFirst("--config=".count))
      : String(argument.dropFirst(2))
    appendOverride(value)
    index += 1
    return true
  }

  private func nextValue() throws -> String {
    guard arguments.indices.contains(index + 1), index + 1 != promptArgumentIndex else {
      throw CodexLaunchContextError.malformedOption
    }
    return arguments[index + 1]
  }

  private mutating func appendOverride(_ value: String) {
    let key = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if key == "notify" {
      explicitNotifyOverride = value
    } else {
      configOverrides.append(value)
    }
  }
}

nonisolated struct CodexLaunchContext: Equatable, Sendable {
  let inheritedCWD: URL
  let effectiveCWD: URL
  let codexHome: URL
  let configOverrides: [String]
  let profileName: String?
  let explicitNotifyOverride: String?

  init(
    inheritedCWD: URL,
    effectiveCWD: URL,
    codexHome: URL,
    configOverrides: [String],
    profileName: String?,
    explicitNotifyOverride: String?
  ) {
    self.inheritedCWD = inheritedCWD.standardizedFileURL
    self.effectiveCWD = effectiveCWD.standardizedFileURL
    self.codexHome = codexHome.standardizedFileURL
    self.configOverrides = configOverrides
    self.profileName = profileName
    self.explicitNotifyOverride = explicitNotifyOverride
  }

  var profileURL: URL? {
    guard let profileName else { return nil }
    return codexHome.appending(path: "\(profileName).config.toml", directoryHint: .notDirectory)
  }

  static func capture(
    invocation: AgentInvocation,
    inheritedCWD: URL,
    dedicatedHome: URL? = nil,
    environment: [String: String],
    promptArgumentIndex: Int? = nil
  ) throws -> CodexLaunchContext {
    let inheritedCWD = inheritedCWD.standardizedFileURL
    var options = CodexLaunchOptionScanner(
      arguments: invocation.arguments,
      promptArgumentIndex: promptArgumentIndex
    )
    try options.scan()
    guard options.cwdValue?.contains("\0") != true, options.profileName?.isEmpty != true,
      options.profileName?.contains("\0") != true, options.profileName?.contains("/") != true,
      options.profileName?.contains("\\") != true
    else {
      throw CodexLaunchContextError.malformedOption
    }
    let effectiveCWD: URL
    if let cwdValue = options.cwdValue {
      guard !cwdValue.isEmpty else { throw CodexLaunchContextError.malformedOption }
      effectiveCWD = URL(filePath: cwdValue, relativeTo: inheritedCWD).standardizedFileURL
    } else {
      effectiveCWD = inheritedCWD
    }
    let codexHome: URL
    if let dedicatedHome {
      codexHome = dedicatedHome
    } else if let configured = environment["CODEX_HOME"], !configured.isEmpty {
      codexHome = URL(filePath: configured, directoryHint: .isDirectory)
    } else if let home = environment["HOME"], !home.isEmpty {
      codexHome = URL(filePath: home, directoryHint: .isDirectory)
        .appending(path: ".codex", directoryHint: .isDirectory)
    } else {
      codexHome = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".codex", directoryHint: .isDirectory)
    }
    return CodexLaunchContext(
      inheritedCWD: inheritedCWD,
      effectiveCWD: effectiveCWD,
      codexHome: codexHome,
      configOverrides: options.configOverrides,
      profileName: options.profileName,
      explicitNotifyOverride: options.explicitNotifyOverride
    )
  }
}

nonisolated struct CodexConfigQuery: Equatable, Sendable {
  nonisolated enum Kind: Equatable, Sendable {
    case base
    case profile(URL)
    case explicitNotify
  }

  let kind: Kind
  let codexHome: URL
  let cwd: URL
  let overrides: [String]
}

nonisolated enum CodexEffectiveNotifyResult: Equatable, Sendable {
  case absent
  case present([String])
  case degraded(String)
}

nonisolated enum CodexConfigReadProtocol {
  static func requestData(cwd: String) -> Data {
    let messages: [[String: Any]] = [
      [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
          "clientInfo": ["name": "prowl", "version": "1"],
          "capabilities": ["experimentalApi": true],
        ],
      ],
      [
        "jsonrpc": "2.0",
        "method": "initialized",
        "params": [:],
      ],
      [
        "jsonrpc": "2.0",
        "id": 2,
        "method": "config/read",
        "params": ["cwd": cwd, "includeLayers": true],
      ],
    ]
    var result = Data()
    for message in messages {
      guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else {
        continue
      }
      result.append(data)
      result.append(UInt8(ascii: "\n"))
    }
    return result
  }

  static func decodeNotify(from transcript: Data) throws -> [String]? {
    for line in transcript.split(separator: UInt8(ascii: "\n")) {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
        continue
      }
      let id = object["id"] as? Int ?? (object["id"] as? NSNumber)?.intValue
      guard id == 2 else { continue }
      guard let result = object["result"] as? [String: Any],
        let config = result["config"] as? [String: Any]
      else {
        throw CodexConfigReadError.malformedResponse
      }
      guard let notify = config["notify"], !(notify is NSNull) else { return nil }
      guard let values = notify as? [Any] else { throw CodexConfigReadError.malformedResponse }
      var argv: [String] = []
      argv.reserveCapacity(values.count)
      for value in values {
        guard let value = value as? String else { throw CodexConfigReadError.malformedResponse }
        argv.append(value)
      }
      return argv
    }
    throw CodexConfigReadError.missingResponse
  }
}

nonisolated enum CodexConfigReadError: Error, Equatable, Sendable {
  case malformedResponse
  case missingResponse
}

nonisolated struct CodexEffectiveNotifyResolver {
  typealias Query = (CodexConfigQuery) async throws -> Data

  private let bundledCLIPath: String?
  private let query: Query

  init(
    bundledCLIPath: String? = nil,
    query: @escaping Query
  ) {
    self.bundledCLIPath = bundledCLIPath
    self.query = query
  }

  func resolve(_ context: CodexLaunchContext) async -> CodexEffectiveNotifyResult {
    do {
      let base = try await resolveQuery(
        CodexConfigQuery(
          kind: .base,
          codexHome: context.codexHome,
          cwd: context.effectiveCWD,
          overrides: context.configOverrides
        )
      )
      var effective = base
      if let profileURL = context.profileURL {
        let profile = try await resolveQuery(
          CodexConfigQuery(
            kind: .profile(profileURL),
            codexHome: context.codexHome,
            cwd: context.effectiveCWD,
            overrides: []
          )
        )
        if profile != nil { effective = profile }
      }
      if let explicit = context.explicitNotifyOverride {
        effective = try await resolveQuery(
          CodexConfigQuery(
            kind: .explicitNotify,
            codexHome: context.codexHome,
            cwd: context.effectiveCWD,
            overrides: [explicit]
          )
        )
      }
      guard let argv = effective else { return .absent }
      guard isValid(argv), !isRecursive(argv) else {
        return .degraded("The effective Codex notifier could not be preserved safely.")
      }
      return .present(argv)
    } catch {
      return .degraded("The effective Codex notifier could not be resolved.")
    }
  }

  private func resolveQuery(_ queryValue: CodexConfigQuery) async throws -> [String]? {
    try CodexConfigReadProtocol.decodeNotify(from: await query(queryValue))
  }

  private func isValid(_ argv: [String]) -> Bool {
    guard !argv.isEmpty, !argv[0].isEmpty, argv.count <= 128 else { return false }
    var total = 0
    for argument in argv {
      guard !argument.contains("\0") else { return false }
      total += argument.utf8.count
      guard total <= 64 * 1_024 else { return false }
    }
    return true
  }

  private func isRecursive(_ argv: [String]) -> Bool {
    guard let bundledCLIPath, argv.first == bundledCLIPath else { return false }
    return argv.dropFirst().starts(with: ["agents", "_hook"])
  }
}
