import Foundation

nonisolated enum ProjectWorkspaceRepositorySourceKind: String, Codable, Equatable, Hashable, Sendable {
  case remote
  case localRepository = "local_repository"
  case bareRepository = "bare_repository"
  case existingPath = "existing_path"
}

nonisolated struct ProjectWorkspaceRepositoryEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
  var id: String
  var name: String
  var role: String?
  var path: String
  var sourceKind: ProjectWorkspaceRepositorySourceKind
  var sourceLocation: String?
  var branchName: String?
  var baseRef: String?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case role
    case path
    case sourceKind = "source_kind"
    case sourceLocation = "source_location"
    case branchName = "branch_name"
    case baseRef = "base_ref"
  }

  init(
    id: String = "",
    name: String = "",
    role: String? = nil,
    path: String = "",
    sourceKind: ProjectWorkspaceRepositorySourceKind = .existingPath,
    sourceLocation: String? = nil,
    branchName: String? = nil,
    baseRef: String? = nil
  ) {
    self.id = id
    self.name = name
    self.role = role
    self.path = path
    self.sourceKind = sourceKind
    self.sourceLocation = sourceLocation
    self.branchName = branchName
    self.baseRef = baseRef
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    role = try container.decodeIfPresent(String.self, forKey: .role)
    path =
      try container.decodeIfPresent(String.self, forKey: .path)
      ?? name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? id.trimmingCharacters(in: .whitespacesAndNewlines)
    sourceKind =
      try container.decodeIfPresent(ProjectWorkspaceRepositorySourceKind.self, forKey: .sourceKind)
      ?? .existingPath
    sourceLocation = try container.decodeIfPresent(String.self, forKey: .sourceLocation)
    branchName = try container.decodeIfPresent(String.self, forKey: .branchName)
    baseRef = try container.decodeIfPresent(String.self, forKey: .baseRef)
  }

  func resolvedURL(relativeTo workspaceRootURL: URL) -> URL {
    let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedPath.hasPrefix("/") {
      return URL(fileURLWithPath: trimmedPath).standardizedFileURL
    }
    return workspaceRootURL.appending(path: trimmedPath).standardizedFileURL
  }
}

nonisolated struct ProjectWorkspace: Codable, Equatable, Hashable, Sendable {
  typealias RepositorySourceKind = ProjectWorkspaceRepositorySourceKind
  typealias RepositoryEntry = ProjectWorkspaceRepositoryEntry

  nonisolated static let metadataDirectoryName = ".prowl"
  nonisolated static let metadataFileName = "workspace.json"

  var id: String
  var title: String
  var description: String
  var taskLinks: [String]
  var repositories: [RepositoryEntry]
  var createdAt: Date?
  var updatedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case description
    case taskLinks = "task_links"
    case repositories
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  init(
    id: String = "",
    title: String = "",
    description: String = "",
    taskLinks: [String] = [],
    repositories: [RepositoryEntry] = [],
    createdAt: Date? = nil,
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.title = title
    self.description = description
    self.taskLinks = taskLinks
    self.repositories = repositories
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    taskLinks = try container.decodeIfPresent([String].self, forKey: .taskLinks) ?? []
    repositories = try container.decodeIfPresent([RepositoryEntry].self, forKey: .repositories) ?? []
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
  }

  static func metadataURL(for rootURL: URL) -> URL {
    rootURL
      .appending(path: metadataDirectoryName)
      .appending(path: metadataFileName)
  }

  static func load(from rootURL: URL) -> ProjectWorkspace? {
    let metadataURL = metadataURL(for: rootURL)
    guard let data = try? Data(contentsOf: metadataURL) else {
      return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard var workspace = try? decoder.decode(ProjectWorkspace.self, from: data) else {
      return nil
    }
    let normalizedRoot = rootURL.standardizedFileURL.path(percentEncoded: false)
    if workspace.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      workspace.id = normalizedRoot
    }
    if workspace.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      workspace.title = rootURL.lastPathComponent.isEmpty ? normalizedRoot : rootURL.lastPathComponent
    }
    return workspace.normalized(relativeTo: rootURL)
  }

  func normalized(relativeTo rootURL: URL) -> ProjectWorkspace {
    var copy = self
    let normalizedRoot = rootURL.standardizedFileURL.path(percentEncoded: false)
    if copy.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      copy.id = normalizedRoot
    }
    copy.title = copy.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if copy.title.isEmpty {
      copy.title = rootURL.lastPathComponent.isEmpty ? normalizedRoot : rootURL.lastPathComponent
    }
    copy.description = copy.description.trimmingCharacters(in: .whitespacesAndNewlines)
    copy.taskLinks = copy.taskLinks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    copy.repositories = copy.repositories.map { entry in
      var entry = entry
      entry.id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
      entry.name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
      entry.path = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
      if entry.id.isEmpty {
        entry.id = entry.path.isEmpty ? entry.name : entry.path
      }
      if entry.name.isEmpty {
        let resolvedURL = entry.resolvedURL(relativeTo: rootURL)
        entry.name = resolvedURL.lastPathComponent.isEmpty ? entry.id : resolvedURL.lastPathComponent
      }
      entry.role = entry.role?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      entry.sourceLocation = entry.sourceLocation?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      entry.branchName = entry.branchName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      entry.baseRef = entry.baseRef?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      return entry
    }
    return copy
  }
}

extension String {
  nonisolated fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
