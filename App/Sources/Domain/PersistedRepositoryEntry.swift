import Foundation

nonisolated struct PersistedRepositoryEntry: Codable, Equatable, Sendable {
  /// The repository ID: a local path, or an encoded remote location (docs-ai 084 D1, D6).
  let path: String
  let kind: Repository.Kind
  /// The host profile of a remote entry, written next to its encoded ID so that the file
  /// reads plainly. The path is the source of truth: the host is always derived from it.
  let host: UUID?

  init(path: String, kind: Repository.Kind) {
    self.path = path
    self.kind = kind
    if case .remote(let hostProfileID, _)? = RepositoryLocation(id: path) {
      host = hostProfileID
    } else {
      host = nil
    }
  }

  private enum CodingKeys: String, CodingKey {
    case path, kind, host
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      path: try container.decode(String.self, forKey: .path),
      kind: try container.decode(Repository.Kind.self, forKey: .kind))
  }

  /// The repository the entry names. A local path becomes a file URL exactly as loading
  /// always built it (`URL(fileURLWithPath:)`), so local repository IDs stay the same.
  var location: RepositoryLocation {
    if RepositoryLocation.hasRemoteForm(path), let location = RepositoryLocation(id: path) {
      return location
    }
    return .local(URL(fileURLWithPath: path))
  }
}
