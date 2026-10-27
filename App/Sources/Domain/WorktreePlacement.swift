import Foundation

/// Where a new worktree goes, by where its repository lives (docs-ai 084 B3d).
///
/// A local repository follows `ProwlPaths`. A remote repository's paths are paths on its
/// host: `~` and a relative path resolve against the host's home and the repository, as
/// text, never against this Mac. By default a remote worktree goes under
/// `<home>/.prowl/repos/<repository>` on the host, as a local one goes under
/// `~/.prowl/repos/<repository>`. The repository's own base directory setting is read as
/// a host path; the global default is a local path and does not apply.
nonisolated enum WorktreePlacement: Equatable, Sendable {
  case local(repositoryRootURL: URL)
  case remote(repositoryPath: String, homeDirectory: String)

  /// The repository root as `GitWorktreeCreateRequest.repoRoot` carries it.
  var repositoryRootURL: URL {
    switch self {
    case .local(let url): url
    case .remote(let path, _): URL(filePath: path, directoryHint: .isDirectory)
    }
  }

  func defaultBaseDirectory(globalDefaultPath: String?, repositoryOverridePath: String?) -> URL {
    switch self {
    case .local(let rootURL):
      return ProwlPaths.worktreeBaseDirectory(
        for: rootURL, globalDefaultPath: globalDefaultPath, repositoryOverridePath: repositoryOverridePath)
    case .remote(let repositoryPath, let home):
      let path =
        Self.hostPath(repositoryOverridePath, relativeTo: repositoryPath, home: home)
        ?? Self.joined(home, ".prowl/repos", Self.repositoryDirectoryName(repositoryPath))
      return URL(filePath: path, directoryHint: .isDirectory)
    }
  }

  /// An explicit destination from the dialog's name and path overrides; nil when neither
  /// is set, so `wt` keeps its `base/<branch>` placement.
  func resolvedDirectory(
    defaultBaseDirectory: URL, nameOverride: String?, pathOverride: String?, branchName: String
  ) -> URL? {
    switch self {
    case .local(let rootURL):
      return ProwlPaths.resolvedWorktreeDirectory(
        defaultBaseDirectory: defaultBaseDirectory, repositoryRootURL: rootURL, nameOverride: nameOverride,
        pathOverride: pathOverride, branchName: branchName)
    case .remote:
      let name = nameOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let path = pathOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !name.isEmpty || !path.isEmpty else { return nil }
      return previewDirectory(
        defaultBaseDirectory: defaultBaseDirectory, nameOverride: nameOverride, pathOverride: pathOverride,
        branchName: branchName)
    }
  }

  /// The destination the dialog previews: the overrides, else the base and the branch.
  func previewDirectory(
    defaultBaseDirectory: URL, nameOverride: String?, pathOverride: String?, branchName: String
  ) -> URL {
    switch self {
    case .local(let rootURL):
      return ProwlPaths.previewWorktreeDirectory(
        defaultBaseDirectory: defaultBaseDirectory, repositoryRootURL: rootURL, nameOverride: nameOverride,
        pathOverride: pathOverride, branchName: branchName)
    case .remote(let repositoryPath, let home):
      let base =
        Self.hostPath(pathOverride, relativeTo: repositoryPath, home: home)
        ?? defaultBaseDirectory.path(percentEncoded: false)
      let name = nameOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let leaf = name.isEmpty ? branchName.trimmingCharacters(in: .whitespacesAndNewlines) : name
      return URL(filePath: leaf.isEmpty ? Self.joined(base) : Self.joined(base, leaf), directoryHint: .isDirectory)
    }
  }

  /// The repository's folder under `.prowl/repos`, by the local rule
  /// (`ProwlPaths.repositoryDirectoryName`) applied to the host path as text.
  static func repositoryDirectoryName(_ repositoryPath: String) -> String {
    let parts = RemotePaths.components(repositoryPath)
    guard let last = parts.last, last != ".bare", last != ".git" else {
      return parts.isEmpty ? "_" : parts.joined(separator: "_")
    }
    return last
  }

  /// Whether `raw` names another user's home (`~user/…`). The host would have to expand
  /// it, so a remote folder refuses it instead of reading it as a relative path.
  static func namesAnotherUsersHome(_ raw: String?) -> Bool {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.hasPrefix("~") && trimmed != "~" && !trimmed.hasPrefix("~/")
  }

  /// `raw` as an absolute host path: `~` is the host's home, a relative path is relative
  /// to `base`. Nil for a blank string.
  static func hostPath(_ raw: String?, relativeTo base: String, home: String) -> String? {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return nil }
    if trimmed == "~" { return joined(home) }
    if trimmed.hasPrefix("~/") { return joined(home, String(trimmed.dropFirst(2))) }
    if trimmed.hasPrefix("/") { return joined(trimmed) }
    return joined(base, trimmed)
  }

  /// The parts joined into one absolute path, with `.` and `..` parts resolved as text.
  private static func joined(_ parts: String...) -> String {
    RemotePaths.canonicalPath(parts.joined(separator: "/"))
  }
}

nonisolated enum WorktreePlacementError: Error, Equatable, LocalizedError {
  /// A remote folder's base directory or path override starts with `~user`.
  case anotherUsersHome(String)

  var errorDescription: String? {
    switch self {
    case .anotherUsersHome(let path):
      String(localized: "Remote projects cannot use another user's home (\(path)). Use an absolute path.")
    }
  }
}
