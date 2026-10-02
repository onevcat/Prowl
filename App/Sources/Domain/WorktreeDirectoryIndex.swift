import Foundation
import IdentifiedCollections

/// Maps a directory an agent runs in to the deepest repository or worktree that contains it.
///
/// Normalizing a path to its canonical form touches the filesystem (a `stat` plus a symlink walk
/// per path component), so every candidate directory is normalized once when the index is built and
/// never again per lookup. A lookup then costs one normalization of the queried directory plus a
/// handful of dictionary probes, instead of re-scanning and re-normalizing every worktree.
nonisolated struct WorktreeDirectoryIndex: Equatable {
  /// Keyed by normalized path components joined back together, so a probe compares whole components
  /// rather than raw string prefixes — `/tmp/repo` must not match a sibling `/tmp/repo2`.
  private var idsByNormalizedPath: [String: Worktree.ID] = [:]
  private var deepestComponentCount = 0

  init() {}

  init(repositories: some Sequence<Repository>) {
    for repository in repositories {
      if repository.capabilities.supportsRunnableFolderActions,
        !repository.capabilities.supportsWorktrees
      {
        insert(id: repository.id, directory: repository.rootURL)
      }
      for worktree in repository.worktrees {
        insert(id: worktree.id, directory: worktree.workingDirectory)
      }
    }
  }

  fileprivate init(normalizedDirectories: [(id: Worktree.ID, directory: URL)]) {
    for entry in normalizedDirectories {
      insertNormalized(id: entry.id, directory: entry.directory)
    }
  }

  private mutating func insert(id: Worktree.ID, directory: URL) {
    insertNormalized(id: id, directory: PathPolicy.normalizeURL(directory))
  }

  private mutating func insertNormalized(id: Worktree.ID, directory: URL) {
    let components = directory.pathComponents
    let key = Self.key(for: components)
    // The first entry registered for a directory wins. This preserves the previous behavior when a
    // plain-folder repository root and its main worktree resolve to the same path.
    guard idsByNormalizedPath[key] == nil else { return }
    idsByNormalizedPath[key] = id
    deepestComponentCount = max(deepestComponentCount, components.count)
  }

  /// Finds the most specific indexed directory containing `workingDirectory`. The walk starts at the
  /// full path and shortens one component at a time, so the deepest match is the first hit.
  func worktreeID(forWorkingDirectory workingDirectory: URL) -> Worktree.ID? {
    guard !idsByNormalizedPath.isEmpty else { return nil }
    var components = PathPolicy.normalizeURL(workingDirectory).pathComponents
    // No indexed directory is deeper than this, so longer prefixes cannot match.
    if components.count > deepestComponentCount {
      components.removeLast(components.count - deepestComponentCount)
    }
    while !components.isEmpty {
      if let id = idsByNormalizedPath[Self.key(for: components)] {
        return id
      }
      components.removeLast()
    }
    return nil
  }

  private static func key(for components: [String]) -> String {
    components.joined(separator: "/")
  }
}

/// Memoizes the index across SwiftUI render passes.
///
/// `SidebarListView.body` re-runs on every agent output tick, and rebuilding the index each time
/// would put one filesystem round-trip per worktree back on the main thread. Repository changes
/// rebuild immediately; otherwise canonical paths are revalidated at a bounded cadence so a live
/// symlink retarget cannot leave the index stale until restart.
@MainActor
enum WorktreeDirectoryIndexCache {
  private static let canonicalRevalidationInterval: Duration = .seconds(1)
  private static var cachedSignature: [Entry]?
  private static var cachedCanonicalSignature: [Entry] = []
  private static var cachedIndex = WorktreeDirectoryIndex()
  private static var nextCanonicalRevalidation: ContinuousClock.Instant?

  /// Resolutions already computed against `cachedIndex`, keyed by the directory as asked for.
  /// A resolution normalizes that directory, so it carries the same symlink assumption the index
  /// does and is dropped on the same cadence.
  private static var cachedResolutions: [URL: Worktree.ID?] = [:]

  /// An agent's working directory is stable for the life of its pane, but a pane can `cd`
  /// anywhere, so the memo is capped rather than assumed bounded by pane count.
  private static let resolutionMemoLimit = 256

  private struct Entry: Equatable {
    let id: Worktree.ID
    let directory: URL
  }

  static func index(
    for repositories: IdentifiedArrayOf<Repository>,
    now: ContinuousClock.Instant = ContinuousClock.now
  ) -> WorktreeDirectoryIndex {
    let signature = signature(for: repositories)
    let repositorySetChanged = signature != cachedSignature
    let canonicalRevalidationIsDue = nextCanonicalRevalidation.map { now >= $0 } ?? true
    guard repositorySetChanged || canonicalRevalidationIsDue else {
      return cachedIndex
    }

    let canonicalSignature = signature.map { entry in
      Entry(id: entry.id, directory: PathPolicy.normalizeURL(entry.directory))
    }
    cachedSignature = signature
    nextCanonicalRevalidation = now.advanced(by: canonicalRevalidationInterval)
    // Resolutions normalize the directory they are asked about, so a symlink retarget can make one
    // stale exactly as it can make the index stale. Clearing here rather than only when the index
    // is rebuilt gives them the same staleness bound the revalidation interval already sets, which
    // still collapses every lookup within an interval down to one.
    cachedResolutions.removeAll(keepingCapacity: true)
    guard canonicalSignature != cachedCanonicalSignature else {
      return cachedIndex
    }

    cachedCanonicalSignature = canonicalSignature
    cachedIndex = WorktreeDirectoryIndex(
      normalizedDirectories: canonicalSignature.map { (id: $0.id, directory: $0.directory) }
    )
    return cachedIndex
  }

  /// Resolves a working directory against the cached index, remembering the answer.
  ///
  /// `WorktreeDirectoryIndex.worktreeID(forWorkingDirectory:)` normalizes the directory it is
  /// asked about, and `PathPolicy.normalizeURL` touches the filesystem — a `stat` plus a symlink
  /// walk. The sidebar resolves every agent row on every render, so without this memo a window
  /// with N agents pays N filesystem round-trips per frame on the main thread, for paths that
  /// almost never change.
  static func worktreeID(
    forWorkingDirectory directory: URL,
    in repositories: IdentifiedArrayOf<Repository>,
    now: ContinuousClock.Instant = ContinuousClock.now
  ) -> Worktree.ID? {
    // Ordered first: a repository-set change or a due revalidation clears the memo, so a stale
    // resolution can never be returned for an index that has moved on.
    let index = index(for: repositories, now: now)
    return worktreeID(forWorkingDirectory: directory, in: index)
  }

  /// Resolves one render batch after validating the repository signature once.
  static func worktreeIDs(
    forWorkingDirectories directories: some Sequence<URL>,
    in repositories: IdentifiedArrayOf<Repository>,
    now: ContinuousClock.Instant = ContinuousClock.now
  ) -> [URL: Worktree.ID] {
    let index = index(for: repositories, now: now)
    var resolved: [URL: Worktree.ID] = [:]
    for directory in directories {
      if let id = worktreeID(forWorkingDirectory: directory, in: index) {
        resolved[directory] = id
      }
    }
    return resolved
  }

  private static func worktreeID(
    forWorkingDirectory directory: URL,
    in index: WorktreeDirectoryIndex
  ) -> Worktree.ID? {
    if let memoized = cachedResolutions[directory] {
      return memoized
    }
    let resolved = index.worktreeID(forWorkingDirectory: directory)
    if cachedResolutions.count >= resolutionMemoLimit {
      cachedResolutions.removeAll(keepingCapacity: true)
    }
    cachedResolutions[directory] = resolved
    return resolved
  }

  /// The id/directory pairs the index is built from, in build order. Comparing these avoids
  /// rebuilding when an unrelated part of a repository changes (a branch rename, a color, an icon).
  private static func signature(for repositories: IdentifiedArrayOf<Repository>) -> [Entry] {
    var entries: [Entry] = []
    for repository in repositories {
      if repository.capabilities.supportsRunnableFolderActions,
        !repository.capabilities.supportsWorktrees
      {
        entries.append(Entry(id: repository.id, directory: repository.rootURL))
      }
      for worktree in repository.worktrees {
        entries.append(Entry(id: worktree.id, directory: worktree.workingDirectory))
      }
    }
    return entries
  }

  /// Drops the memo so a test starts from a known state.
  static func reset() {
    cachedSignature = nil
    cachedCanonicalSignature = []
    cachedIndex = WorktreeDirectoryIndex()
    nextCanonicalRevalidation = nil
    cachedResolutions.removeAll()
  }
}
