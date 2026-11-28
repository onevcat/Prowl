import Foundation

/// The model suggestions a profile editor offers for one runtime. When the
/// installed agent has cached its own model catalog, that list wins: it follows
/// the agent's version and account. Otherwise the adapter's built-in list is the
/// fallback. Suggestions never rewrite a model value that a profile already saved.
nonisolated struct AgentModelCatalog: Equatable, Sendable {
  nonisolated struct Model: Equatable, Sendable {
    let id: String
    /// `nil` when the source does not say. An empty list means the model takes
    /// no reasoning effort.
    let reasoningEfforts: [String]?

    init(id: String, reasoningEfforts: [String]? = nil) {
      self.id = id
      self.reasoningEfforts = reasoningEfforts
    }
  }

  enum Source: Equatable, Sendable {
    case installedAgent
    case builtIn
  }

  /// Models shown at the top level of the suggestion menu.
  static let primaryLimit = 6
  /// Models shown in the "More Models" submenu.
  static let overflowLimit = 24

  let primary: [Model]
  let overflow: [Model]
  let source: Source

  /// - Parameters:
  ///   - models: All models, most relevant first.
  ///   - primaryCount: How many leading models the source marks as primary.
  ///     The primary limit still applies.
  init(models: [Model], primaryCount: Int, source: Source) {
    var seen: Set<String> = []
    let unique = models.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    let split = min(max(primaryCount, 0), Self.primaryLimit, unique.count)
    primary = Array(unique.prefix(split))
    overflow = Array(unique.dropFirst(split).prefix(Self.overflowLimit))
    self.source = source
  }

  var allModelIDs: [String] {
    (primary + overflow).map(\.id)
  }

  /// The reasoning efforts the catalog lists for `modelID`, or `nil` when the
  /// model is not in the catalog or the catalog does not say.
  func reasoningEfforts(for modelID: String?) -> [String]? {
    guard let modelID else { return nil }
    return (primary + overflow).first { $0.id == modelID }?.reasoningEfforts
  }

  static func builtIn(for runtime: AgentProfileRuntime) -> AgentModelCatalog? {
    guard let suggestions = AgentRuntimeAdapterRegistry.profileAdapter(for: runtime)?.modelSuggestions,
      !suggestions.isEmpty
    else { return nil }
    return AgentModelCatalog(
      models: suggestions.map { Model(id: $0) },
      primaryCount: primaryLimit,
      source: .builtIn
    )
  }
}

// MARK: - Installed agent catalogs

// Both formats are private caches of the agent CLIs, with no stability promise.
// The parsers read only the fields they need and return nil for anything they
// cannot use, so a format change falls back to the built-in list.

nonisolated extension AgentModelCatalog {
  /// Codex writes `$CODEX_HOME/models_cache.json`. It is the same JSON that
  /// `codex debug models` prints. The TUI picker shows the `list` models in
  /// `priority` order.
  static func parseCodex(_ data: Data) -> AgentModelCatalog? {
    guard let cache = try? snakeCaseDecoder.decode(CodexModelCache.self, from: data) else { return nil }
    let listed = cache.models.enumerated()
      .filter { ($0.element.visibility ?? "list") == "list" }
      .sorted { ($0.element.priority ?? .max, $0.offset) < ($1.element.priority ?? .max, $1.offset) }
      .map { Model(id: $0.element.slug, reasoningEfforts: $0.element.supportedReasoningLevels?.map(\.effort)) }
    guard !listed.isEmpty else { return nil }
    return AgentModelCatalog(models: listed, primaryCount: primaryLimit, source: .installedAgent)
  }

  /// Claude Code writes `$CLAUDE_CONFIG_DIR/cache/model-catalog/<account>-cc.json`.
  /// Its `/model` picker shows the `main` section first and the rest under
  /// "more models".
  static func parseClaude(_ data: Data) -> AgentModelCatalog? {
    ClaudeModelCatalogFile.decode(data).flatMap(claudeCatalog(from:))
  }

  fileprivate static func claudeCatalog(from file: ClaudeModelCatalogFile) -> AgentModelCatalog? {
    let entries = file.catalog.config.models
    let main = entries.filter { $0.section == "main" }
    let rest = entries.filter { $0.section != "main" }
    let models = (main + rest).map { Model(id: $0.id, reasoningEfforts: $0.reasoningEfforts) }
    guard !models.isEmpty else { return nil }
    return AgentModelCatalog(models: models, primaryCount: main.count, source: .installedAgent)
  }

  fileprivate static var snakeCaseDecoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }
}

private nonisolated struct CodexModelCache: Decodable {
  let models: [CodexModelEntry]
}

private nonisolated struct CodexModelEntry: Decodable {
  let slug: String
  let visibility: String?
  let priority: Int?
  let supportedReasoningLevels: [CodexReasoningLevel]?
}

private nonisolated struct CodexReasoningLevel: Decodable {
  let effort: String
}

private nonisolated struct ClaudeModelCatalogFile: Decodable {
  let fetchedAt: Double?
  let catalog: ClaudeModelCatalogBody

  static func decode(_ data: Data) -> ClaudeModelCatalogFile? {
    try? AgentModelCatalog.snakeCaseDecoder.decode(ClaudeModelCatalogFile.self, from: data)
  }
}

private nonisolated struct ClaudeModelCatalogBody: Decodable {
  let config: ClaudeModelCatalogConfig
}

private nonisolated struct ClaudeModelCatalogConfig: Decodable {
  let models: [ClaudeModelCatalogEntry]
}

private nonisolated struct ClaudeModelCatalogEntry: Decodable {
  let id: String
  let section: String?
  let runtime: ClaudeModelRuntime?
  let thinking: ClaudeModelThinking?

  var reasoningEfforts: [String]? {
    if let levels = runtime?.effortLevels { return levels }
    if let options = thinking?.effortOptions { return options.map(\.id) }
    if thinking?.type == "none" { return [] }
    return nil
  }
}

private nonisolated struct ClaudeModelRuntime: Decodable {
  let effortLevels: [String]?
}

private nonisolated struct ClaudeModelThinking: Decodable {
  let type: String?
  let effortOptions: [ClaudeModelEffortOption]?
}

private nonisolated struct ClaudeModelEffortOption: Decodable {
  let id: String
}

// MARK: - Loading

nonisolated enum AgentModelCatalogLoader {
  /// Reads the installed agent's catalog off the main actor. Falls back to the
  /// built-in list; returns nil when the runtime has no model suggestions.
  @concurrent
  static func load(for runtime: AgentProfileRuntime, dedicatedHome: URL?) async -> AgentModelCatalog? {
    catalog(
      for: runtime,
      homes: homes(
        for: runtime,
        dedicatedHome: dedicatedHome,
        environment: ProcessInfo.processInfo.environment,
        userHome: FileManager.default.homeDirectoryForCurrentUser
      )
    )
  }

  /// The first home with a readable catalog wins. A dedicated profile home has
  /// no catalog until the agent runs there once, so the default home follows it.
  static func catalog(for runtime: AgentProfileRuntime, homes: [URL]) -> AgentModelCatalog? {
    for home in homes {
      if let catalog = installedCatalog(for: runtime, home: home) { return catalog }
    }
    return AgentModelCatalog.builtIn(for: runtime)
  }

  static func homes(
    for runtime: AgentProfileRuntime,
    dedicatedHome: URL?,
    environment: [String: String],
    userHome: URL
  ) -> [URL] {
    let variable: String
    switch runtime {
    case .codex: variable = "CODEX_HOME"
    case .claude: variable = "CLAUDE_CONFIG_DIR"
    default: return []
    }
    let defaultHome: URL =
      if let configured = environment[variable], !configured.isEmpty {
        URL(filePath: configured, directoryHint: .isDirectory)
      } else {
        userHome.appending(path: runtime.defaultHomeDirectoryName, directoryHint: .isDirectory)
      }
    return [dedicatedHome, defaultHome].compactMap(\.self)
  }

  private static func installedCatalog(for runtime: AgentProfileRuntime, home: URL) -> AgentModelCatalog? {
    switch runtime {
    case .codex:
      guard let data = try? Data(contentsOf: home.appending(path: "models_cache.json")) else { return nil }
      return AgentModelCatalog.parseCodex(data)
    case .claude:
      return newestClaudeCatalog(in: home.appending(path: "cache/model-catalog", directoryHint: .isDirectory))
    default:
      return nil
    }
  }

  /// One file per signed-in account; the most recently fetched one describes
  /// the account in use.
  private static func newestClaudeCatalog(in directory: URL) -> AgentModelCatalog? {
    guard
      let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    else { return nil }
    let newest =
      files
      .filter { $0.lastPathComponent.hasSuffix("-cc.json") }
      .compactMap { url in (try? Data(contentsOf: url)).flatMap(ClaudeModelCatalogFile.decode) }
      .max { ($0.fetchedAt ?? 0) < ($1.fetchedAt ?? 0) }
    return newest.flatMap(AgentModelCatalog.claudeCatalog(from:))
  }
}
