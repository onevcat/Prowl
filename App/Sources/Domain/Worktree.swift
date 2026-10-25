import Foundation

nonisolated struct Worktree: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let detail: String
  /// The worktree's working directory.
  let location: RepositoryLocation
  /// The root of the worktree's repository, on the same host. It differs from
  /// `location` for a linked worktree.
  let repositoryLocation: RepositoryLocation
  let createdAt: Date?
  let isMain: Bool

  nonisolated init(
    id: String,
    name: String,
    detail: String,
    location: RepositoryLocation,
    repositoryLocation: RepositoryLocation,
    createdAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.detail = detail
    self.location = location
    self.repositoryLocation = repositoryLocation
    self.createdAt = createdAt
    // Pre-compute the main-worktree flag at construction time so that hot SwiftUI
    // paths never call the expensive `URL.standardizedFileURL` getter during view
    // updates. The fast equality check covers the common case where callers
    // already pass normalized URLs; the standardized fallback protects against
    // any future call site that forgets to normalize first.
    self.isMain =
      switch (location, repositoryLocation) {
      case (.local(let workingDirectory), .local(let repositoryRootURL)):
        workingDirectory == repositoryRootURL
          || workingDirectory.standardizedFileURL == repositoryRootURL.standardizedFileURL
      case (.remote, .remote):
        location == repositoryLocation
      default:
        false
      }
  }

  /// The ID is the encoded location (docs-ai 084 D1).
  nonisolated init(
    name: String,
    detail: String,
    location: RepositoryLocation,
    repositoryLocation: RepositoryLocation,
    createdAt: Date? = nil
  ) {
    self.init(
      id: location.id,
      name: name,
      detail: detail,
      location: location,
      repositoryLocation: repositoryLocation,
      createdAt: createdAt
    )
  }

  nonisolated init(
    id: String,
    name: String,
    detail: String,
    workingDirectory: URL,
    repositoryRootURL: URL,
    createdAt: Date? = nil
  ) {
    self.init(
      id: id,
      name: name,
      detail: detail,
      location: .local(workingDirectory),
      repositoryLocation: .local(repositoryRootURL),
      createdAt: createdAt
    )
  }

  /// The working directory on this Mac. Nil for a remote worktree.
  var localURL: URL? {
    location.localURL
  }

  /// The repository root on this Mac. Nil for a remote worktree.
  var repositoryLocalURL: URL? {
    repositoryLocation.localURL
  }
}

extension Worktree {
  /// Environment variables exposed to all Prowl scripts.
  var scriptEnvironment: [String: String] {
    [
      "PROWL_WORKTREE_PATH": location.path,
      "PROWL_ROOT_PATH": repositoryLocation.path,
    ]
  }

  /// Shell export statements for prepending to scripts.
  var scriptEnvironmentExportPrefix: String {
    scriptEnvironment
      .sorted(by: { $0.key < $1.key })
      .map { "export \($0.key)='\($0.value.replacing("'", with: "'\"'\"'"))'" }
      .joined(separator: "\n") + "\n"
  }
}
