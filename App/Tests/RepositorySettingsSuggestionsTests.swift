import ComposableArchitecture
import Dependencies
import Foundation
import Testing

@testable import supacode

@MainActor
struct RepositorySettingsSuggestionsTests {
  private let fixture = RepositorySymbolSuggestions(
    primary: "cat",
    alternates: ["dog", "bird", "fish", "hare"],
    reason: "Directly depicts the project's mascot.",
    source: .readme,
    usedAI: true
  )

  private func makeStore(
    client: RepositorySymbolSuggestionClient
  ) -> TestStore<RepositorySettingsFeature.State, RepositorySettingsFeature.Action> {
    TestStore(
      initialState: RepositorySettingsFeature.State(
        rootURL: URL(fileURLWithPath: "/tmp/repo-1"),
        repositoryID: "repo-1",
        repositoryKind: .plain,
        settings: .default,
        userSettings: .default
      )
    ) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.repositorySymbolSuggestionClient = client
    }
  }

  @Test func suggestIconGeneratesWhenNothingIsCached() async {
    let generateCalls = LockIsolated(0)
    let fixture = fixture
    let store = makeStore(
      client: RepositorySymbolSuggestionClient(
        cachedSuggestions: { _ in nil },
        generateSuggestions: { _, _, _ in
          generateCalls.withValue { $0 += 1 }
          return fixture
        }
      )
    )

    await store.send(.suggestIconTapped) {
      $0.isSymbolPickerPresented = true
      $0.symbolSuggestions = .loading
    }
    await store.receive(\.symbolSuggestionsLoaded) {
      $0.symbolSuggestions = .loaded(fixture)
    }
    await store.finish()

    #expect(generateCalls.value == 1)
  }

  @Test func suggestIconResolvesFromCacheWithoutGenerating() async {
    let generateCalls = LockIsolated(0)
    let fixture = fixture
    let store = makeStore(
      client: RepositorySymbolSuggestionClient(
        cachedSuggestions: { _ in fixture },
        generateSuggestions: { _, _, _ in
          generateCalls.withValue { $0 += 1 }
          return fixture
        }
      )
    )

    await store.send(.suggestIconTapped) {
      $0.isSymbolPickerPresented = true
      $0.symbolSuggestions = .loading
    }
    await store.receive(\.symbolSuggestionsLoaded) {
      $0.symbolSuggestions = .loaded(fixture)
    }
    await store.finish()

    #expect(generateCalls.value == 0)
  }

  @Test func chooseSymbolStaysIdleWithoutCache() async {
    let store = makeStore(
      client: RepositorySymbolSuggestionClient(
        cachedSuggestions: { _ in nil },
        generateSuggestions: { _, _, _ in
          Issue.record("Choose Symbol must never trigger generation")
          throw CancellationError()
        }
      )
    )

    await store.send(.chooseSymbolTapped) {
      $0.isSymbolPickerPresented = true
    }
    await store.finish()
  }

  @Test func chooseSymbolSurfacesCachedRun() async {
    let fixture = fixture
    let store = makeStore(
      client: RepositorySymbolSuggestionClient(
        cachedSuggestions: { _ in fixture },
        generateSuggestions: { _, _, _ in
          Issue.record("Choose Symbol must never trigger generation")
          throw CancellationError()
        }
      )
    )

    await store.send(.chooseSymbolTapped) {
      $0.isSymbolPickerPresented = true
    }
    await store.receive(\.symbolSuggestionsLoaded) {
      $0.symbolSuggestions = .loaded(fixture)
    }
    await store.finish()
  }

  @Test func regenerateBypassesCache() async {
    let generateCalls = LockIsolated(0)
    let fixture = fixture
    let store = makeStore(
      client: RepositorySymbolSuggestionClient(
        cachedSuggestions: { _ in fixture },
        generateSuggestions: { _, _, _ in
          generateCalls.withValue { $0 += 1 }
          return fixture
        }
      )
    )

    await store.send(.regenerateSuggestionsTapped) {
      $0.symbolSuggestions = .loading
    }
    await store.receive(\.symbolSuggestionsLoaded) {
      $0.symbolSuggestions = .loaded(fixture)
    }
    await store.finish()

    #expect(generateCalls.value == 1)
  }

  @Test func dismissingSheetCancelsInFlightGeneration() async {
    let store = makeStore(
      client: RepositorySymbolSuggestionClient(
        cachedSuggestions: { _ in nil },
        generateSuggestions: { _, _, _ in
          // Parks until the surrounding task is cancelled, mirroring a
          // long model call that honors cooperative cancellation.
          let (stream, _) = AsyncStream<Never>.makeStream()
          for await _ in stream {}
          throw CancellationError()
        }
      )
    )

    await store.send(.suggestIconTapped) {
      $0.isSymbolPickerPresented = true
      $0.symbolSuggestions = .loading
    }
    await store.send(.symbolPickerDismissed) {
      $0.isSymbolPickerPresented = false
      $0.symbolSuggestions = .idle
    }
    await store.finish()
  }

  @Test func dismissingSheetKeepsFinishedResults() async {
    let fixture = fixture
    let store = makeStore(
      client: RepositorySymbolSuggestionClient(
        cachedSuggestions: { _ in nil },
        generateSuggestions: { _, _, _ in fixture }
      )
    )

    await store.send(.suggestIconTapped) {
      $0.isSymbolPickerPresented = true
      $0.symbolSuggestions = .loading
    }
    await store.receive(\.symbolSuggestionsLoaded) {
      $0.symbolSuggestions = .loaded(fixture)
    }
    await store.send(.symbolPickerDismissed) {
      $0.isSymbolPickerPresented = false
    }
    await store.finish()
  }

  @Test func generationFailureIsSurfaced() async {
    struct Boom: LocalizedError {
      var errorDescription: String? { "boom" }
    }
    let store = makeStore(
      client: RepositorySymbolSuggestionClient(
        cachedSuggestions: { _ in nil },
        generateSuggestions: { _, _, _ in throw Boom() }
      )
    )

    await store.send(.suggestIconTapped) {
      $0.isSymbolPickerPresented = true
      $0.symbolSuggestions = .loading
    }
    await store.receive(\.symbolSuggestionsFailed) {
      $0.symbolSuggestions = .failed("boom")
    }
    await store.finish()
  }

  @Test func suggestWhileLoadedShowsExistingResultsWithoutNewRun() async {
    let generateCalls = LockIsolated(0)
    let fixture = fixture
    let store = makeStore(
      client: RepositorySymbolSuggestionClient(
        cachedSuggestions: { _ in nil },
        generateSuggestions: { _, _, _ in
          generateCalls.withValue { $0 += 1 }
          return fixture
        }
      )
    )

    await store.send(.suggestIconTapped) {
      $0.isSymbolPickerPresented = true
      $0.symbolSuggestions = .loading
    }
    await store.receive(\.symbolSuggestionsLoaded) {
      $0.symbolSuggestions = .loaded(fixture)
    }
    await store.send(.symbolPickerDismissed) {
      $0.isSymbolPickerPresented = false
    }
    // Re-invoking Suggest an Icon shows the finished run; Regenerate is
    // the explicit path to a fresh one.
    await store.send(.suggestIconTapped) {
      $0.isSymbolPickerPresented = true
    }
    await store.finish()

    #expect(generateCalls.value == 1)
  }
}
