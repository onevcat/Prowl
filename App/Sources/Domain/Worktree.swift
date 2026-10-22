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

  /// The local working directory. A forward kept while call sites move to
  /// `location` or `localURL` (docs-ai 084 A3); it traps for a remote worktree.
  var workingDirectory: URL {
    guard let localURL else { preconditionFailure("workingDirectory read on remote worktree \(id)") }
    return localURL
  }

  /// The local repository root. A forward kept while call sites move to
  /// `repositoryLocation` or `repositoryLocalURL` (docs-ai 084 A3); it traps
  /// for a remote worktree.
  var repositoryRootURL: URL {
    guard let repositoryLocalURL else {
      preconditionFailure("repositoryRootURL read on remote worktree \(id)")
    }
    return repositoryLocalURL
  }
}

extension Worktree {
  /// Environment variables exposed to all Prowl scripts.
  var scriptEnvironment: [String: String] {
    [
      "PROWL_WORKTREE_PATH": workingDirectory.path(percentEncoded: false),
      "PROWL_ROOT_PATH": repositoryRootURL.path(percentEncoded: false),
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
