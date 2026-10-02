import Dependencies
import Foundation
import Sharing

/// Persisted dictionary keyed by `Repository.ID` (the path-derived id
/// from `RepositoryEntryNormalizer`) holding each repo's user-picked
/// icon and color. One global file rather than per-repo so the sidebar
/// — which renders every row — gets every appearance in a single
/// `@Shared` read; per-repo settings would force one file load per
/// row at startup.
///
/// On-disk location: `~/.prowl/repository-appearances.json`. Repos
/// without an entry behave exactly like before (no icon, accent color
/// fallback) so the file is purely additive.
nonisolated struct RepositoryAppearancesKeyID: Hashable, Sendable {}

nonisolated enum RepositoryAppearancesFileURLKey: DependencyKey {
  static var liveValue: URL { SupacodePaths.repositoryAppearancesURL }
  static var previewValue: URL { SupacodePaths.repositoryAppearancesURL }
  static var testValue: URL { SupacodePaths.repositoryAppearancesURL }
}

extension DependencyValues {
  nonisolated var repositoryAppearancesFileURL: URL {
    get { self[RepositoryAppearancesFileURLKey.self] }
    set { self[RepositoryAppearancesFileURLKey.self] = newValue }
  }
}

nonisolated struct RepositoryAppearancesKey: SharedKey {
  var id: RepositoryAppearancesKeyID {
    RepositoryAppearancesKeyID()
  }

  func load(
    context _: LoadContext<[Repository.ID: RepositoryAppearance]>,
    continuation: LoadContinuation<[Repository.ID: RepositoryAppearance]>
  ) {
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.repositoryAppearancesFileURL) var url
    let decoder = JSONDecoder()
    if let data = try? storage.load(url),
      let entries = try? decoder.decode([Repository.ID: RepositoryAppearance].self, from: data)
    {
      continuation.resume(returning: entries)
      return
    }
    continuation.resumeReturningInitialValue()
  }

  func subscribe(
    context _: LoadContext<[Repository.ID: RepositoryAppearance]>,
    subscriber _: SharedSubscriber<[Repository.ID: RepositoryAppearance]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: [Repository.ID: RepositoryAppearance],
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.repositoryAppearancesFileURL) var url
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      // Drop empty entries before writing so the file stays tight when
      // a user clears both icon and color — the absence of a key is
      // the canonical "no appearance" state.
      let pruned = value.filter { !$0.value.isEmpty }
      let data = try encoder.encode(pruned)
      try storage.save(data, url)
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }
}

nonisolated extension SharedReaderKey where Self == RepositoryAppearancesKey.Default {
  static var repositoryAppearances: Self {
    Self[RepositoryAppearancesKey(), default: [:]]
  }
}
