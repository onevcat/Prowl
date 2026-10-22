import Dependencies
import Foundation
import Sharing

nonisolated struct RepositoryEntriesKeyID: Hashable, Sendable {}

nonisolated enum RepositoryEntriesFileURLKey: DependencyKey {
  static var liveValue: URL { ProwlPaths.repositoryEntriesURL }
  static var previewValue: URL { ProwlPaths.repositoryEntriesURL }
  static var testValue: URL { ProwlPaths.repositoryEntriesURL }
}

extension DependencyValues {
  nonisolated var repositoryEntriesFileURL: URL {
    get { self[RepositoryEntriesFileURLKey.self] }
    set { self[RepositoryEntriesFileURLKey.self] = newValue }
  }
}

nonisolated struct RepositoryEntriesKey: SharedKey {
  var id: RepositoryEntriesKeyID {
    RepositoryEntriesKeyID()
  }

  func load(
    context _: LoadContext<[PersistedRepositoryEntry]>,
    continuation: LoadContinuation<[PersistedRepositoryEntry]>
  ) {
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.repositoryEntriesFileURL) var repositoryEntriesFileURL
    let decoder = JSONDecoder()
    if let data = try? storage.load(repositoryEntriesFileURL),
      let entries = try? decoder.decode([PersistedRepositoryEntry].self, from: data)
    {
      continuation.resume(returning: RepositoryEntryNormalizer.normalize(entries))
      return
    }

    @Shared(.settingsFile) var settingsFile: SettingsFile
    let entries = RepositoryEntryNormalizer.normalize(
      settingsFile.repositoryRoots.map { PersistedRepositoryEntry(path: $0, kind: .git) }
    )
    continuation.resume(returning: entries)
  }

  func subscribe(
    context _: LoadContext<[PersistedRepositoryEntry]>,
    subscriber _: SharedSubscriber<[PersistedRepositoryEntry]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: [PersistedRepositoryEntry],
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.repositoryEntriesFileURL) var repositoryEntriesFileURL
    let normalized = RepositoryEntryNormalizer.normalize(value)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      let data = try encoder.encode(normalized)
      try storage.save(data, repositoryEntriesFileURL)
      @Shared(.settingsFile) var settingsFile: SettingsFile
      $settingsFile.withLock {
        $0.repositoryRoots = normalized.map(\.path)
      }
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }
}

nonisolated struct RepositoryRootsKeyID: Hashable, Sendable {}

nonisolated struct RepositoryRootsKey: SharedKey {
  var id: RepositoryRootsKeyID {
    RepositoryRootsKeyID()
  }

  func load(
    context _: LoadContext<[String]>,
    continuation: LoadContinuation<[String]>
  ) {
    @Shared(.repositoryEntries) var entries: [PersistedRepositoryEntry]
    continuation.resume(returning: entries.map(\.path))
  }

  func subscribe(
    context _: LoadContext<[String]>,
    subscriber _: SharedSubscriber<[String]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: [String],
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Shared(.repositoryEntries) var repositoryEntries: [PersistedRepositoryEntry]
    let normalized = RepositoryIDNormalizer.normalizeRoots(value)
    let entries = normalized.map { PersistedRepositoryEntry(path: $0, kind: .git) }
    $repositoryEntries.withLock {
      $0 = entries
    }
    continuation.resume()
  }
}

nonisolated struct PinnedWorktreeIDsKeyID: Hashable, Sendable {}

nonisolated struct PinnedWorktreeIDsKey: SharedKey {
  var id: PinnedWorktreeIDsKeyID {
    PinnedWorktreeIDsKeyID()
  }

  func load(
    context _: LoadContext<[Worktree.ID]>,
    continuation: LoadContinuation<[Worktree.ID]>
  ) {
    @Shared(.settingsFile) var settingsFile: SettingsFile
    let ids = $settingsFile.withLock { settings in
      let normalized = RepositoryIDNormalizer.normalize(settings.pinnedWorktreeIDs)
      if normalized != settings.pinnedWorktreeIDs {
        settings.pinnedWorktreeIDs = normalized
      }
      return normalized
    }
    continuation.resume(returning: ids)
  }

  func subscribe(
    context _: LoadContext<[Worktree.ID]>,
    subscriber _: SharedSubscriber<[Worktree.ID]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: [Worktree.ID],
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Shared(.settingsFile) var settingsFile: SettingsFile
    let normalized = RepositoryIDNormalizer.normalize(value)
    $settingsFile.withLock {
      $0.pinnedWorktreeIDs = normalized
    }
    continuation.resume()
  }
}

nonisolated extension SharedReaderKey where Self == RepositoryRootsKey.Default {
  static var repositoryRoots: Self {
    Self[RepositoryRootsKey(), default: []]
  }
}

nonisolated extension SharedReaderKey where Self == RepositoryEntriesKey.Default {
  static var repositoryEntries: Self {
    Self[RepositoryEntriesKey(), default: []]
  }
}

nonisolated extension SharedReaderKey where Self == PinnedWorktreeIDsKey.Default {
  static var pinnedWorktreeIDs: Self {
    Self[PinnedWorktreeIDsKey(), default: []]
  }
}

/// Normalizes stored repository and worktree IDs (and legacy root paths). A
/// local path is normalized as a path; a remote ID or a string in neither form
/// is kept exactly as stored (docs-ai 084 D1).
nonisolated enum RepositoryIDNormalizer {
  static func normalize(_ ids: [String]) -> [String] {
    var seen = Set<String>()
    var normalized: [String] = []
    normalized.reserveCapacity(ids.count)
    for id in ids {
      guard let resolved = normalize(id) else { continue }
      if seen.insert(resolved).inserted {
        normalized.append(resolved)
      }
    }
    return normalized
  }

  /// Nil for a blank string.
  static func normalize(_ id: String, resolvingSymlinks: Bool = false) -> String? {
    guard RepositoryLocation.isLocalPathForm(id) else {
      return id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : id
    }
    return PathPolicy.normalizePath(id, resolvingSymlinks: resolvingSymlinks)
  }

  /// Normalizes stored repository roots: entry paths and legacy roots. A
  /// remote ID is kept as stored; every other string is a local path, resolved
  /// as before (a relative path against the home directory).
  static func normalizeRoots(_ roots: [String]) -> [String] {
    var seen = Set<String>()
    var normalized: [String] = []
    normalized.reserveCapacity(roots.count)
    for root in roots {
      guard let resolved = normalizeRoot(root) else { continue }
      if seen.insert(resolved).inserted {
        normalized.append(resolved)
      }
    }
    return normalized
  }

  /// Nil for a blank string.
  static func normalizeRoot(_ root: String) -> String? {
    guard !RepositoryLocation.hasRemoteForm(root) else { return root }
    return PathPolicy.normalizePath(root, resolvingSymlinks: false)
  }
}

nonisolated enum RepositoryEntryNormalizer {
  static func normalize(_ entries: [PersistedRepositoryEntry]) -> [PersistedRepositoryEntry] {
    var order: [String] = []
    var kindByPath: [String: Repository.Kind] = [:]

    for entry in entries {
      guard let normalizedPath = RepositoryIDNormalizer.normalizeRoot(entry.path) else { continue }
      if let existing = kindByPath[normalizedPath] {
        kindByPath[normalizedPath] = resolvedKind(existing: existing, incoming: entry.kind)
        continue
      }
      order.append(normalizedPath)
      kindByPath[normalizedPath] = entry.kind
    }

    return order.compactMap { path in
      guard let kind = kindByPath[path] else { return nil }
      if !RepositoryLocation.hasRemoteForm(path), ProjectWorkspace.hasMetadata(at: URL(fileURLWithPath: path)) {
        return PersistedRepositoryEntry(path: path, kind: .plain)
      }
      return PersistedRepositoryEntry(path: path, kind: kind)
    }
  }

  private static func resolvedKind(
    existing: Repository.Kind,
    incoming: Repository.Kind
  ) -> Repository.Kind {
    if existing == .git || incoming == .git {
      return .git
    }
    return .plain
  }

}
