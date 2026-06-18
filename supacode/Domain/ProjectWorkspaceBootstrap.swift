import Foundation

nonisolated enum ProjectWorkspaceBootstrapScriptKind: String, Codable, Equatable, Hashable,
  Sendable
{
  case userProfile = "user_profile"
  case repoLocal = "repo_local"
}

nonisolated enum ProjectWorkspaceBootstrapTiming: String, Codable, Equatable, Hashable, Sendable {
  case create
  case onAdd = "on_add"
  case manual
}

nonisolated struct ProjectWorkspaceRepositoryBootstrap: Codable, Equatable, Hashable, Sendable {
  var scriptKind: ProjectWorkspaceBootstrapScriptKind
  var scriptIDs: [String]
  var scriptPath: String?
  var runOn: Set<ProjectWorkspaceBootstrapTiming>
  var required: Bool

  enum CodingKeys: String, CodingKey {
    case scriptKind = "script_kind"
    case scriptID = "script_id"
    case scriptIDs = "script_ids"
    case scriptPath = "script_path"
    case runOn = "run_on"
    case required
  }

  var scriptID: String? {
    scriptIDs.first
  }

  init(
    scriptKind: ProjectWorkspaceBootstrapScriptKind,
    scriptID: String? = nil,
    scriptIDs: [String] = [],
    scriptPath: String? = nil,
    runOn: Set<ProjectWorkspaceBootstrapTiming> = [],
    required: Bool = false
  ) {
    self.scriptKind = scriptKind
    self.scriptIDs = Self.normalizedScriptIDs(scriptIDs + [scriptID].compactMap(\.self))
    self.scriptPath = scriptPath
    self.runOn = runOn
    self.required = required
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    scriptKind =
      try container.decodeIfPresent(ProjectWorkspaceBootstrapScriptKind.self, forKey: .scriptKind)
      ?? .userProfile
    let scriptIDs = try container.decodeIfPresent([String].self, forKey: .scriptIDs) ?? []
    let scriptID = try container.decodeIfPresent(String.self, forKey: .scriptID)
    self.scriptIDs = Self.normalizedScriptIDs(scriptIDs + [scriptID].compactMap(\.self))
    scriptPath = try container.decodeIfPresent(String.self, forKey: .scriptPath)
    runOn =
      Set(try container.decodeIfPresent([ProjectWorkspaceBootstrapTiming].self, forKey: .runOn) ?? [])
    required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(scriptKind, forKey: .scriptKind)
    if !scriptIDs.isEmpty {
      try container.encode(scriptIDs, forKey: .scriptIDs)
    }
    try container.encodeIfPresent(scriptPath, forKey: .scriptPath)
    try container.encode(runOn.sorted { $0.rawValue < $1.rawValue }, forKey: .runOn)
    try container.encode(required, forKey: .required)
  }

  private static func normalizedScriptIDs(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
        continue
      }
      result.append(trimmed)
    }
    return result
  }
}

nonisolated struct ProjectWorkspaceBootstrapProfile: Codable, Equatable, Identifiable, Sendable {
  var id: String
  var name: String
  var description: String
  var shell: String?
  var script: String
  var timeoutSeconds: Int

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case description
    case shell
    case script
    case timeoutSeconds = "timeout_seconds"
  }

  init(
    id: String,
    name: String,
    description: String = "",
    shell: String? = nil,
    script: String,
    timeoutSeconds: Int = 300
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.shell = shell
    self.script = script
    self.timeoutSeconds = timeoutSeconds
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    shell = try container.decodeIfPresent(String.self, forKey: .shell)
    script = try container.decodeIfPresent(String.self, forKey: .script) ?? ""
    timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 300
  }

  var normalized: ProjectWorkspaceBootstrapProfile {
    ProjectWorkspaceBootstrapProfile(
      id: id.trimmingCharacters(in: .whitespacesAndNewlines),
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      description: description.trimmingCharacters(in: .whitespacesAndNewlines),
      shell: Self.trimmedNonEmpty(shell),
      script: script,
      timeoutSeconds: max(1, timeoutSeconds)
    )
  }

  private static func trimmedNonEmpty(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

nonisolated struct ProjectWorkspaceBootstrapContext: Equatable, Sendable {
  var workspaceRootURL: URL
  var repositoryRootURL: URL
  var repository: ProjectWorkspace.RepositoryEntry
  var timing: ProjectWorkspaceBootstrapTiming
}

nonisolated struct ProjectWorkspaceBootstrapRunner: Sendable {
  var run:
    @Sendable (
      _ bootstrap: ProjectWorkspaceRepositoryBootstrap,
      _ context: ProjectWorkspaceBootstrapContext
    ) async throws -> Void
}
