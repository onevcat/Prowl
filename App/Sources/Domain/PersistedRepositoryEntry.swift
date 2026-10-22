import Foundation

nonisolated struct PersistedRepositoryEntry: Codable, Equatable, Sendable {
  let path: String
  let kind: Repository.Kind

  /// The repository the entry names. A local path becomes a file URL exactly as loading
  /// always built it (`URL(fileURLWithPath:)`), so local repository IDs stay the same.
  var location: RepositoryLocation {
    if RepositoryLocation.hasRemoteForm(path), let location = RepositoryLocation(id: path) {
      return location
    }
    return .local(URL(fileURLWithPath: path))
  }
}
