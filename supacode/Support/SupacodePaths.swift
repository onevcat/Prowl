import Foundation

nonisolated enum SupacodePaths {
  static var baseDirectory: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let prowlDir = home.appending(path: ".prowl", directoryHint: .isDirectory)
    let legacyDir = home.appending(path: ".supacode", directoryHint: .isDirectory)
    // Migrate from legacy ~/.supacode to ~/.prowl on first access
    if !FileManager.default.fileExists(atPath: prowlDir.path(percentEncoded: false)),
      FileManager.default.fileExists(atPath: legacyDir.path(percentEncoded: false))
    {
      try? FileManager.default.copyItem(at: legacyDir, to: prowlDir)
    }
    return prowlDir
  }

  static var repositorySettingsDirectory: URL {
    baseDirectory.appending(path: "repo", directoryHint: .isDirectory)
  }

  static var appSupportDirectory: URL {
    let appSupport =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? baseDirectory
    return
      appSupport
      .appending(path: "com.onevcat.prowl", directoryHint: .isDirectory)
      .standardizedFileURL
  }

  static var cacheDirectory: URL {
    appSupportDirectory.appending(path: "cache", directoryHint: .isDirectory)
  }

  /// The agent-facing documentation set bundled inside the app
  /// (`Prowl.app/Contents/Resources/docs`). Shipped so users and their
  /// AI agents can read the manual straight from the installed app.
  static var bundledDocsURL: URL? {
    Bundle.main.resourceURL?.appending(path: "docs", directoryHint: .isDirectory)
  }

  /// On-disk path to the bundled docs index (`docs/README.md`), e.g.
  /// `/Applications/Prowl.app/Contents/Resources/docs/README.md`. `nil` only
  /// if the bundle has no resource directory (should not happen at runtime).
  static var bundledDocsReadmePath: String? {
    bundledDocsURL?
      .appending(path: "README.md", directoryHint: .notDirectory)
      .path(percentEncoded: false)
  }

  /// On-disk path to the bundled docs directory itself.
  static var bundledDocsDirectoryPath: String? {
    bundledDocsURL?.path(percentEncoded: false)
  }

  static var reposDirectory: URL {
    baseDirectory.appending(path: "repos", directoryHint: .isDirectory)
  }

  static var workspacesDirectory: URL {
    baseDirectory.appending(path: "workspaces", directoryHint: .isDirectory)
  }

  static var bootstrapProfilesURL: URL {
    baseDirectory.appending(path: "bootstrap-profiles.json", directoryHint: .notDirectory)
  }

  static func repositoryDirectory(for rootURL: URL) -> URL {
    let name = repositoryDirectoryName(for: rootURL)
    return reposDirectory.appending(path: name, directoryHint: .isDirectory)
  }

  static func normalizedWorktreeBaseDirectoryPath(
    _ rawPath: String?,
    repositoryRootURL: URL? = nil
  ) -> String? {
    guard let rawPath else {
      return nil
    }
    return PathPolicy.normalizePath(
      rawPath,
      relativeTo: repositoryRootURL,
      resolvingSymlinks: false
    )
  }

  /// Resolves an explicit worktree directory from the dialog's optional name /
  /// path overrides. Returns `nil` when neither is set so callers keep `wt`'s
  /// default `base/<branch>` placement. The path override sets the parent
  /// directory (default: the resolved base); the name override sets the leaf
  /// folder (default: the branch name).
  static func resolvedWorktreeDirectory(
    defaultBaseDirectory: URL,
    repositoryRootURL: URL,
    nameOverride: String?,
    pathOverride: String?,
    branchName: String
  ) -> URL? {
    let trimmedName = nameOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let trimmedPath = pathOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmedName.isEmpty || !trimmedPath.isEmpty else {
      return nil
    }
    return worktreePlacement(
      defaultBaseDirectory: defaultBaseDirectory,
      repositoryRootURL: repositoryRootURL,
      trimmedName: trimmedName,
      trimmedPath: trimmedPath,
      branchName: branchName
    )
  }

  /// Always-concrete counterpart to `resolvedWorktreeDirectory` for the dialog's
  /// live destination preview. Falls back to the default base and branch name
  /// when the overrides are empty.
  static func previewWorktreeDirectory(
    defaultBaseDirectory: URL,
    repositoryRootURL: URL,
    nameOverride: String?,
    pathOverride: String?,
    branchName: String
  ) -> URL {
    worktreePlacement(
      defaultBaseDirectory: defaultBaseDirectory,
      repositoryRootURL: repositoryRootURL,
      trimmedName: nameOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      trimmedPath: pathOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      branchName: branchName
    )
  }

  /// Shared base + leaf join for both resolvers. `trimmedName` / `trimmedPath`
  /// are expected pre-trimmed by callers; only the branch-name fallback is
  /// re-trimmed defensively.
  private static func worktreePlacement(
    defaultBaseDirectory: URL,
    repositoryRootURL: URL,
    trimmedName: String,
    trimmedPath: String,
    branchName: String
  ) -> URL {
    let baseURL: URL
    if let normalizedPath = normalizedWorktreeBaseDirectoryPath(
      trimmedPath,
      repositoryRootURL: repositoryRootURL
    ) {
      baseURL = URL(filePath: normalizedPath, directoryHint: .isDirectory).standardizedFileURL
    } else {
      baseURL = defaultBaseDirectory.standardizedFileURL
    }
    let leaf =
      trimmedName.isEmpty
      ? branchName.trimmingCharacters(in: .whitespacesAndNewlines)
      : trimmedName
    guard !leaf.isEmpty else {
      return baseURL
    }
    return baseURL.appending(path: leaf, directoryHint: .isDirectory).standardizedFileURL
  }

  static func worktreeBaseDirectory(
    for repositoryRootURL: URL,
    globalDefaultPath: String?,
    repositoryOverridePath: String?
  ) -> URL {
    let rootURL = repositoryRootURL.standardizedFileURL
    if let repositoryOverridePath = normalizedWorktreeBaseDirectoryPath(
      repositoryOverridePath,
      repositoryRootURL: rootURL
    ) {
      return PathPolicy.normalizeURL(
        URL(filePath: repositoryOverridePath, directoryHint: .isDirectory),
        resolvingSymlinks: false
      )
    }
    if let globalDefaultPath = normalizedWorktreeBaseDirectoryPath(globalDefaultPath) {
      return PathPolicy.normalizeURL(
        URL(filePath: globalDefaultPath, directoryHint: .isDirectory),
        resolvingSymlinks: false
      )
      .appending(path: repositoryDirectoryName(for: rootURL), directoryHint: .isDirectory)
      .standardizedFileURL
    }
    return repositoryDirectory(for: rootURL)
  }

  static func exampleWorktreePath(
    for repositoryRootURL: URL,
    globalDefaultPath: String?,
    repositoryOverridePath: String?,
    branchName: String = "swift-otter"
  ) -> String {
    worktreeBaseDirectory(
      for: repositoryRootURL,
      globalDefaultPath: globalDefaultPath,
      repositoryOverridePath: repositoryOverridePath
    )
    .appending(path: branchName, directoryHint: .isDirectory)
    .standardizedFileURL
    .path(percentEncoded: false)
  }

  static var settingsURL: URL {
    baseDirectory.appending(path: "settings.json", directoryHint: .notDirectory)
  }

  static var repositorySnapshotURL: URL {
    cacheDirectory.appending(path: "repository-snapshot.json", directoryHint: .notDirectory)
  }

  static var terminalLayoutSnapshotURL: URL {
    cacheDirectory.appending(path: "terminal-layout-snapshot.json", directoryHint: .notDirectory)
  }

  static var repositoryEntriesURL: URL {
    baseDirectory.appending(path: "repository-entries.json", directoryHint: .notDirectory)
  }

  static var repositoryAppearancesURL: URL {
    baseDirectory.appending(path: "repository-appearances.json", directoryHint: .notDirectory)
  }

  /// Directory where user-imported repository icon images live, scoped
  /// per-repo so cleanup is automatic when the per-repo settings
  /// directory is removed.
  static func repositoryIconsDirectory(for rootURL: URL) -> URL {
    repositorySettingsDirectory(for: rootURL)
      .appending(path: "icons", directoryHint: .isDirectory)
  }

  /// Resolved file URL for a stored icon filename. The filename is the
  /// only thing persisted in `RepositoryAppearance` so that moving a
  /// repository (or renaming its directory) leaves the artifact alone.
  static func repositoryIconFileURL(filename: String, repositoryRootURL rootURL: URL) -> URL {
    repositoryIconsDirectory(for: rootURL)
      .appending(path: filename, directoryHint: .notDirectory)
  }

  static func migrateLegacyCacheFilesIfNeeded(
    fileManager: FileManager = .default,
    legacyDirectory: URL? = nil,
    cacheDirectory: URL? = nil
  ) throws {
    let sourceDirectory = (legacyDirectory ?? baseDirectory).standardizedFileURL
    let destinationDirectory = (cacheDirectory ?? self.cacheDirectory).standardizedFileURL
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

    let fileNames = [
      "repository-snapshot.json",
      "terminal-layout-snapshot.json",
    ]

    for name in fileNames {
      let legacyURL = sourceDirectory.appending(path: name, directoryHint: .notDirectory)
      let destinationURL = destinationDirectory.appending(path: name, directoryHint: .notDirectory)
      guard !fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) else {
        continue
      }
      guard fileManager.fileExists(atPath: legacyURL.path(percentEncoded: false)) else {
        continue
      }
      do {
        try fileManager.moveItem(at: legacyURL, to: destinationURL)
      } catch {
        try fileManager.copyItem(at: legacyURL, to: destinationURL)
        try? fileManager.removeItem(at: legacyURL)
      }
    }
  }

  static func repositorySettingsURL(for rootURL: URL) -> URL {
    repositorySettingsDirectory(for: rootURL)
      .appending(path: "prowl.json", directoryHint: .notDirectory)
  }

  static func userRepositorySettingsURL(for rootURL: URL) -> URL {
    repositorySettingsDirectory(for: rootURL)
      .appending(path: "prowl.onevcat.json", directoryHint: .notDirectory)
  }

  /// Legacy location: ~/.prowl/repo/<name>/supacode.json (pre-rename)
  static func legacyRepositorySettingsURL(for rootURL: URL) -> URL {
    repositorySettingsDirectory(for: rootURL)
      .appending(path: "supacode.json", directoryHint: .notDirectory)
  }

  /// Legacy location: ~/.prowl/repo/<name>/supacode.onevcat.json (pre-rename)
  static func legacyUserRepositorySettingsURL(for rootURL: URL) -> URL {
    repositorySettingsDirectory(for: rootURL)
      .appending(path: "supacode.onevcat.json", directoryHint: .notDirectory)
  }

  /// Legacy location: <repo-root>/supacode.json (original upstream location)
  static func originalLegacyRepositorySettingsURL(for rootURL: URL) -> URL {
    rootURL.standardizedFileURL.appending(path: "supacode.json", directoryHint: .notDirectory)
  }

  /// Legacy location: <repo-root>/supacode.onevcat.json (original upstream location)
  static func originalLegacyUserRepositorySettingsURL(for rootURL: URL) -> URL {
    rootURL.standardizedFileURL.appending(path: "supacode.onevcat.json", directoryHint: .notDirectory)
  }

  private static func repositorySettingsDirectory(for rootURL: URL) -> URL {
    let name = repositorySettingsDirectoryName(for: rootURL)
    return repositorySettingsDirectory.appending(path: name, directoryHint: .isDirectory)
  }

  private static func repositoryDirectoryName(for rootURL: URL) -> String {
    let repoName = rootURL.lastPathComponent
    if repoName.isEmpty || repoName == ".bare" || repoName == ".git" {
      let path = rootURL.standardizedFileURL.path(percentEncoded: false)
      let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      if trimmed.isEmpty {
        return "_"
      }
      return trimmed.replacing("/", with: "_")
    }
    return repoName
  }

  private static func repositorySettingsDirectoryName(for rootURL: URL) -> String {
    let repoName = rootURL.standardizedFileURL.lastPathComponent
    if repoName.isEmpty || repoName == "/" {
      return "_"
    }
    return repoName
  }
}
