import Foundation

nonisolated struct Worktree: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let detail: String
  let workingDirectory: URL
  let repositoryRootURL: URL
  let createdAt: Date?
  let isMain: Bool

  nonisolated init(
    id: String,
    name: String,
    detail: String,
    workingDirectory: URL,
    repositoryRootURL: URL,
    createdAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.detail = detail
    self.workingDirectory = workingDirectory
    self.repositoryRootURL = repositoryRootURL
    self.createdAt = createdAt
    // Pre-compute the main-worktree flag at construction time so that hot SwiftUI
    // paths never call the expensive `URL.standardizedFileURL` getter during view
    // updates. The fast equality check covers the common case where callers
    // already pass normalized URLs; the standardized fallback protects against
    // any future call site that forgets to normalize first.
    self.isMain =
      workingDirectory == repositoryRootURL
      || workingDirectory.standardizedFileURL == repositoryRootURL.standardizedFileURL
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
