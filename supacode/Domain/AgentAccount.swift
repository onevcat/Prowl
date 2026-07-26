import Foundation

/// A named agent identity: one directory holding a Claude Code login and a Codex
/// login. Selecting an account only swaps `CLAUDE_CONFIG_DIR` and `CODEX_HOME`
/// for panes launched afterwards, so different accounts can run side by side.
nonisolated enum AgentAccount {
  /// What gets persisted: whitespace trimmed, empty means "not set". Names that
  /// could not work as a directory are kept as typed so the user's input is
  /// never silently discarded — `normalizedName` rejects them at the point of use.
  static func storedName(_ name: String?) -> String? {
    guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }

  /// What can actually be used: account names become directory names, so
  /// anything that could escape the accounts directory is rejected.
  static func normalizedName(_ name: String?) -> String? {
    guard let trimmed = storedName(name) else { return nil }
    guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else { return nil }
    return trimmed
  }

  /// Resolution order: the repository override wins, then the longest matching
  /// path rule, then the global default. `nil` means the system-wide
  /// `~/.claude` and `~/.codex` accounts.
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
  }

  private static func directories(
    forAccountNamed name: String?,
    accountsDirectory: URL
  ) -> (claude: URL, codex: URL)? {
    guard let name = normalizedName(name) else { return nil }
    // No `directoryHint: .isDirectory`: it would leave a trailing slash in the
    // exported paths.
    let base = accountsDirectory.appending(path: name)
    return (base.appending(path: "claude"), base.appending(path: "codex"))
  }

  /// The most specific matching rule wins; rules of equal length resolve to the
  /// first one in the list.
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

  /// `URL(fileURLWithPath:)` appends a trailing slash for paths that exist on
  /// disk as directories, so both sides of a prefix comparison have to be
  /// stripped of it — otherwise a rule only ever matches paths that do not exist.
  private static func standardizedPath(_ path: String) -> String {
    guard !path.isEmpty else { return "" }
    var value = URL(fileURLWithPath: path).standardizedFileURL.path(percentEncoded: false)
    while value.count > 1, value.hasSuffix("/") {
      value.removeLast()
    }
    return value
  }
}

/// Maps a repository location to an account, so repositories under a work
/// directory pick up the work account without per-repository setup.
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
