import Foundation

nonisolated enum SymlinkPreservingFileWriterError: Error, Equatable {
  /// The destination resolves through a symlink cycle, so there is no real file
  /// to write without clobbering one of the links.
  case symbolicLinkCycle(URL)
  /// The chain exceeds the kernel's symlink-resolution limit, so the loader
  /// could never follow it; refuse rather than write a file it can't read back.
  case symbolicLinkChainTooDeep(URL)
  /// The owner-only temporary file could not be created in the target's
  /// directory, so there is nothing safe to rename into place.
  case temporaryFileCreationFailed(URL)
  /// `rename(2)` of the temporary file onto the target failed with this errno.
  case renameFailed(URL, code: Int32)
  /// Exclusive publication failed, for example because the destination now exists.
  case linkFailed(URL, code: Int32)
}

/// Atomic file writes that survive a symlinked destination. When the target is a
/// symlink (e.g. a `~/.prowl/settings.json` linked into a dotfiles repo), the
/// write follows the link to its real file so the temp+rename replaces the
/// target, leaving the link intact, instead of overwriting the link with a
/// regular file.
nonisolated enum SymlinkPreservingFileWriter {
  /// Atomically writes `data` to `url`, following a symlink at `url` so the link
  /// is preserved. Creates the destination's own parent directory when missing,
  /// but never a symlink target's parent (a link into a missing directory fails
  /// the write rather than fabricating a phantom tree there).
  static func write(_ data: Data, to url: URL) throws {
    let target = try resolvedTarget(for: url)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try publish(data, to: target, replacing: true)
  }

  /// Creates a migration destination without replacing a competing file or link.
  /// A legacy symlink keeps its resolved target instead of becoming a detached copy.
  static func create(_ data: Data, to url: URL, preservingLinkAt source: URL?) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let source, try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
      let target = try resolvedTarget(for: source)
      _ = try Data(contentsOf: target)
      try fileManager.createSymbolicLink(at: url, withDestinationURL: target)
    } else {
      try publish(data, to: url, replacing: false)
    }
  }

  private static func publish(_ data: Data, to target: URL, replacing: Bool) throws {
    let fileManager = FileManager.default
    // Settings may carry secrets (agent profile env overrides can hold API
    // keys, docs-ai 053/004): the temporary file is born 0600, and the
    // same-directory rename(2) both replaces the target atomically — through a
    // symlink at `url`, preserving the link — and carries those owner-only
    // permissions with it, so the content is never readable by other users,
    // not even between write and rename.
    let temporary =
      target
      .deletingLastPathComponent()
      .appending(path: ".\(target.lastPathComponent).tmp-\(UUID().uuidString)", directoryHint: .notDirectory)
    let temporaryPath = temporary.path(percentEncoded: false)
    guard
      fileManager.createFile(
        atPath: temporaryPath,
        contents: data,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw SymlinkPreservingFileWriterError.temporaryFileCreationFailed(target)
    }
    defer { try? fileManager.removeItem(at: temporary) }
    let targetPath = target.path(percentEncoded: false)
    if replacing {
      guard rename(temporaryPath, targetPath) == 0 else {
        throw SymlinkPreservingFileWriterError.renameFailed(target, code: errno)
      }
    } else {
      // link(2) publishes the complete 0600 file atomically and refuses EEXIST.
      // The temporary name is then removed; the source file is never hard-linked.
      guard link(temporaryPath, targetPath) == 0 else {
        throw SymlinkPreservingFileWriterError.linkFailed(target, code: errno)
      }
    }
  }

  /// Best-effort owner-only migration for files written before saves enforced
  /// 0600 (docs-ai 053/004). Runs on load so a legacy 0644 settings file stops
  /// being world-readable the first time it is touched, not on its next save.
  static func restrictToOwnerOnly(_ url: URL) {
    guard let target = try? resolvedTarget(for: url) else { return }
    let path = target.path(percentEncoded: false)
    let fileManager = FileManager.default
    guard
      let permissions = (try? fileManager.attributesOfItem(atPath: path))?[.posixPermissions] as? Int,
      permissions != 0o600
    else { return }
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
  }

  /// macOS resolves at most MAXSYMLINKS (32) links before ELOOP, so a deeper
  /// chain is one the loader's `Data(contentsOf:)` could never read back.
  private static let maxFollowedSymbolicLinks = 32

  /// Follows a symlink chain at `url` to its final real file. Returns `url`
  /// unchanged when it is not a symlink (including a not-yet-created file).
  /// Relative link targets resolve against the link's real directory so a link
  /// under a symlinked parent still lands on the file the kernel would. Throws
  /// on a cycle or an over-deep chain rather than silently overwriting a link in
  /// the loop, and surfaces a real read error rather than misreading an
  /// unreadable link as a plain file (which would clobber it).
  private static func resolvedTarget(for url: URL) throws -> URL {
    let fileManager = FileManager.default
    var current = url
    var visited: Set<String> = []
    while true {
      let isSymbolicLink: Bool
      do {
        isSymbolicLink = try current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false
      } catch CocoaError.fileReadNoSuchFile {
        return current
      }
      guard isSymbolicLink else { return current }
      let linkPath = current.path(percentEncoded: false)
      guard visited.insert(linkPath).inserted else {
        throw SymlinkPreservingFileWriterError.symbolicLinkCycle(url)
      }
      guard visited.count <= Self.maxFollowedSymbolicLinks else {
        throw SymlinkPreservingFileWriterError.symbolicLinkChainTooDeep(url)
      }
      let destination = try fileManager.destinationOfSymbolicLink(atPath: linkPath)
      // A relative target resolves against the link's real directory; an absolute one ignores the base.
      let base =
        destination.hasPrefix("/") ? nil : current.deletingLastPathComponent().resolvingSymlinksInPath()
      current = URL(filePath: destination, directoryHint: .notDirectory, relativeTo: base).standardizedFileURL
    }
  }
}
