import Foundation

/// A named agent identity: one directory holding a Claude Code login and a Codex
/// login, selected per pane through `CLAUDE_CONFIG_DIR` and `CODEX_HOME`.
nonisolated enum AgentAccount {
  /// What gets persisted. Unusable names are kept as typed rather than dropped;
  /// `normalizedName` rejects them at the point of use.
  static func storedName(_ name: String?) -> String? {
    guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }

  /// What can be used: the name becomes a directory name, so anything that could
  /// escape the accounts directory is rejected.
  static func normalizedName(_ name: String?) -> String? {
    guard let trimmed = storedName(name) else { return nil }
    guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else { return nil }
    return trimmed
  }

  /// `nil` means the system-wide `~/.claude` and `~/.codex` logins.
  static func resolvedName(
    repositoryRootURL: URL,
    repositoryOverride: String?,
    globalDefault: String?,
    rules: [AgentAccountRule]
  ) -> String? {
    if let override = normalizedName(repositoryOverride) { return override }
    if let matched = matchingRuleAccount(repositoryRootURL: repositoryRootURL, rules: rules) { return matched }
    return normalizedName(globalDefault)
  }

  static func environment(
    forAccountNamed name: String?,
    accountsDirectory: URL = SupacodePaths.agentAccountsDirectory
  ) -> [String: String] {
    guard let directories = directories(forAccountNamed: name, accountsDirectory: accountsDirectory) else {
      return [:]
    }
    return [
      "CLAUDE_CONFIG_DIR": directories.claude.path(percentEncoded: false),
      "CODEX_HOME": directories.codex.path(percentEncoded: false),
    ]
  }

  /// Config that belongs to the user rather than to a login. Without these links
  /// an account starts as an empty profile — no permissions, hooks, agents or
  /// plugins — because `CLAUDE_CONFIG_DIR` and `CODEX_HOME` relocate the whole
  /// configuration, not just the credentials.
  static let sharedClaudeEntries = ["settings.json", "CLAUDE.md", "agents", "commands", "skills", "plugins"]
  static let sharedCodexEntries = ["config.toml", "AGENTS.md", "skills", "plugins"]

  /// `codex` refuses to start when `CODEX_HOME` points at a missing directory,
  /// so the account directories must exist before a pane launches its shell.
  static func prepareDirectories(
    forAccountNamed name: String?,
    accountsDirectory: URL = SupacodePaths.agentAccountsDirectory
  ) throws {
    guard let directories = directories(forAccountNamed: name, accountsDirectory: accountsDirectory) else {
      return
    }
    for url in [directories.claude, directories.codex] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    linkSharedConfig(into: directories.claude, from: systemClaudeDirectory, entries: sharedClaudeEntries)
    linkSharedConfig(into: directories.codex, from: systemCodexDirectory, entries: sharedCodexEntries)
  }

  /// Links each entry that exists in the user's own configuration and is not
  /// already present in the account. Anything the account owns is left alone, so
  /// a per-account override is never overwritten.
  static func linkSharedConfig(into accountDirectory: URL, from source: URL, entries: [String]) {
    let fileManager = FileManager.default
    for name in entries {
      let origin = source.appending(path: name)
      let destination = accountDirectory.appending(path: name)
      guard fileManager.fileExists(atPath: origin.path(percentEncoded: false)),
        (try? destination.checkResourceIsReachable()) != true,
        (try? fileManager.destinationOfSymbolicLink(atPath: destination.path(percentEncoded: false))) == nil
      else { continue }
      try? fileManager.createSymbolicLink(at: destination, withDestinationURL: origin)
    }
  }

  /// The configuration a pane would use with no account selected. An ambient
  /// `CLAUDE_CONFIG_DIR` wins, matching what the CLI itself would read.
  static var systemClaudeDirectory: URL {
    systemDirectory(environmentKey: "CLAUDE_CONFIG_DIR", fallback: ".claude")
  }

  static var systemCodexDirectory: URL {
    systemDirectory(environmentKey: "CODEX_HOME", fallback: ".codex")
  }

  private static func systemDirectory(environmentKey: String, fallback: String) -> URL {
    if let value = ProcessInfo.processInfo.environment[environmentKey], !value.isEmpty {
      return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appending(path: fallback)
  }

  private static func directories(
    forAccountNamed name: String?,
    accountsDirectory: URL
  ) -> (claude: URL, codex: URL)? {
    guard let name = normalizedName(name) else { return nil }
    // `directoryHint: .isDirectory` would leave a trailing slash in the exports.
    let base = accountsDirectory.appending(path: name)
    return (base.appending(path: "claude"), base.appending(path: "codex"))
  }

  /// Longest matching prefix wins; equal lengths keep the first rule.
  private static func matchingRuleAccount(repositoryRootURL: URL, rules: [AgentAccountRule]) -> String? {
    let path = standardizedPath(repositoryRootURL.path(percentEncoded: false))
    var bestPrefixLength = -1
    var bestAccount: String?
    for rule in rules {
      let prefix = standardizedPath(NSString(string: rule.pathPrefix).expandingTildeInPath)
      guard !prefix.isEmpty, path == prefix || path.hasPrefix(prefix + "/") else { continue }
      guard prefix.count > bestPrefixLength else { continue }
      bestPrefixLength = prefix.count
      bestAccount = rule.account
    }
    return normalizedName(bestAccount)
  }

  /// `URL(fileURLWithPath:)` appends a trailing slash for directories that exist,
  /// so both sides must be stripped or a rule only matches paths that do not.
  private static func standardizedPath(_ path: String) -> String {
    guard !path.isEmpty else { return "" }
    var value = URL(fileURLWithPath: path).standardizedFileURL.path(percentEncoded: false)
    while value.count > 1, value.hasSuffix("/") {
      value.removeLast()
    }
    return value
  }
}

nonisolated struct AgentAccountRule: Codable, Equatable, Hashable, Sendable, Identifiable {
  var id: String
  var pathPrefix: String
  var account: String

  init(id: String = UUID().uuidString, pathPrefix: String = "", account: String = "") {
    self.id = id
    self.pathPrefix = pathPrefix
    self.account = account
  }

  private enum CodingKeys: String, CodingKey {
    case id, pathPrefix, account
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // A missing id must not fail the whole settings decode.
    id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
    pathPrefix = try container.decodeIfPresent(String.self, forKey: .pathPrefix) ?? ""
    account = try container.decodeIfPresent(String.self, forKey: .account) ?? ""
  }
}
