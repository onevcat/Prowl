import Dependencies
import Foundation
import GlyphonKit

/// Dependency surface for the user-invoked "Suggest an Icon" flow.
/// Results are cached in memory per repository for the app session so
/// reopening the picker shows the previous run instantly; only an
/// explicit Regenerate spends another model call.
nonisolated struct RepositorySymbolSuggestionClient: Sendable {
  var cachedSuggestions: @Sendable (_ repositoryID: Repository.ID) async -> RepositorySymbolSuggestions?
  /// Builds the input locally, runs GlyphonKit's recommender, caches
  /// and returns the result. Cooperatively cancellable — cancelling the
  /// surrounding task throws `CancellationError` promptly, even
  /// mid-model-call.
  var generateSuggestions:
    @Sendable (
      _ repositoryID: Repository.ID,
      _ rootURL: URL,
      _ repositoryDisplayName: String
    ) async throws -> RepositorySymbolSuggestions
}

/// Session-scoped engine behind the live client. An actor so the lazy
/// GlyphonKit database load and the cache stay data-race free; nothing
/// here is persisted to disk.
private actor RepositorySymbolSuggestionEngine {
  static let shared = RepositorySymbolSuggestionEngine()

  private var glyphon: Glyphon?
  private var cache: [Repository.ID: RepositorySymbolSuggestions] = [:]

  func cached(_ repositoryID: Repository.ID) -> RepositorySymbolSuggestions? {
    cache[repositoryID]
  }

  func generate(
    repositoryID: Repository.ID,
    rootURL: URL,
    repositoryDisplayName: String
  ) async throws -> RepositorySymbolSuggestions {
    let input = RepositorySuggestionInput.build(
      rootURL: rootURL,
      repositoryDisplayName: repositoryDisplayName
    )
    let glyphon = try loadGlyphon()
    let recommendation = try await glyphon.recommend(from: input.text)
    let suggestions = RepositorySymbolSuggestions(
      primary: recommendation.symbol.name,
      alternates: recommendation.alternates.map(\.name),
      reason: recommendation.reason,
      source: input.source,
      usedAI: recommendation.usedAI
    )
    cache[repositoryID] = suggestions
    return suggestions
  }

  private func loadGlyphon() throws -> Glyphon {
    if let glyphon {
      return glyphon
    }
    // Loads the bundled symbol database (~9k symbols) once per session.
    let loaded = try Glyphon()
    glyphon = loaded
    return loaded
  }
}

nonisolated enum RepositorySymbolSuggestionClientKey: DependencyKey {
  static var liveValue: RepositorySymbolSuggestionClient {
    RepositorySymbolSuggestionClient(
      cachedSuggestions: { repositoryID in
        await RepositorySymbolSuggestionEngine.shared.cached(repositoryID)
      },
      generateSuggestions: { repositoryID, rootURL, repositoryDisplayName in
        try await RepositorySymbolSuggestionEngine.shared.generate(
          repositoryID: repositoryID,
          rootURL: rootURL,
          repositoryDisplayName: repositoryDisplayName
        )
      }
    )
  }

  static var previewValue: RepositorySymbolSuggestionClient { noSuggestions }
  static var testValue: RepositorySymbolSuggestionClient { noSuggestions }

  private static var noSuggestions: RepositorySymbolSuggestionClient {
    struct Unavailable: Error {}
    return RepositorySymbolSuggestionClient(
      cachedSuggestions: { _ in nil },
      generateSuggestions: { _, _, _ in throw Unavailable() }
    )
  }
}

extension DependencyValues {
  nonisolated var repositorySymbolSuggestionClient: RepositorySymbolSuggestionClient {
    get { self[RepositorySymbolSuggestionClientKey.self] }
    set { self[RepositorySymbolSuggestionClientKey.self] = newValue }
  }
}
