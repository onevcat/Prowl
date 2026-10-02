import Dependencies
import Foundation

/// File-system gateway for user-imported repository icon images. Wraps
/// the actual disk operations behind closures so both the live build
/// (real `FileManager`) and tests (in-memory) can drive the same code
/// paths without forking implementations.
///
/// All filenames returned by the store are bare names (e.g.
/// `"3F2D…ABC.svg"`) — never absolute paths — so the persisted
/// `RepositoryAppearance.icon` stays portable: moving a repository
/// directory takes its icons with it without rewriting JSON.
nonisolated struct RepositoryIconAssetStore: Sendable {
  /// Imports a user-picked image into the per-repo icons directory and
  /// returns the bare filename to persist. The implementation chooses
  /// the filename (UUID + extension), creating intermediate directories
  /// as needed.
  var importImage:
    @Sendable (
      _ sourceURL: URL,
      _ repositoryRootURL: URL
    ) throws -> String

  /// Removes a previously-imported image. No-op when the file is
  /// already gone (idempotent so reset/replace can call without
  /// guarding against stale state).
  var remove:
    @Sendable (
      _ filename: String,
      _ repositoryRootURL: URL
    ) throws -> Void

  /// Returns whether a previously-stored filename still resolves to an
  /// existing file. Renderers use this to decide whether to fall back.
  var exists:
    @Sendable (
      _ filename: String,
      _ repositoryRootURL: URL
    ) -> Bool
}

nonisolated extension RepositoryIconAssetStore {
  static var liveValue: RepositoryIconAssetStore {
    fileSystemValue(repositoryIconsDirectory: SupacodePaths.repositoryIconsDirectory(for:))
  }

  static func fileSystemValue(
    repositoryIconsDirectory: @escaping @Sendable (_ repositoryRootURL: URL) -> URL
  ) -> RepositoryIconAssetStore {
    RepositoryIconAssetStore(
      importImage: { sourceURL, rootURL in
        // No extension whitelist — the file picker filters down to
        // image UTTypes already, and anything that NSImage can't
        // render later falls back to the dashed-questionmark
        // placeholder in `RepositoryIconImage`. The `.svg` suffix
        // remains the lone meaningful signal because it gates the
        // template-tinting branch downstream; everything else is
        // treated as an opaque bitmap.
        let normalizedExt =
          sourceURL.pathExtension.lowercased().isEmpty
          ? "img"
          : sourceURL.pathExtension.lowercased()
        let directory = repositoryIconsDirectory(rootURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "\(UUID().uuidString.lowercased()).\(normalizedExt)"
        let destination = directory.appending(path: filename, directoryHint: .notDirectory)
        let data = try Data(contentsOf: sourceURL)
        try data.write(to: destination, options: [.atomic])
        return filename
      },
      remove: { filename, rootURL in
        let url = repositoryIconsDirectory(rootURL)
          .appending(path: filename, directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
          try FileManager.default.removeItem(at: url)
        }
      },
      exists: { filename, rootURL in
        let url = repositoryIconsDirectory(rootURL)
          .appending(path: filename, directoryHint: .notDirectory)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
      }
    )
  }
}

nonisolated enum RepositoryIconAssetStoreKey: DependencyKey {
  static var liveValue: RepositoryIconAssetStore { .liveValue }
  static var previewValue: RepositoryIconAssetStore { .liveValue }
  static var testValue: RepositoryIconAssetStore { .liveValue }
}

extension DependencyValues {
  nonisolated var repositoryIconAssetStore: RepositoryIconAssetStore {
    get { self[RepositoryIconAssetStoreKey.self] }
    set { self[RepositoryIconAssetStoreKey.self] = newValue }
  }
}
