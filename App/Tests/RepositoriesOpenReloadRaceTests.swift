import ComposableArchitecture
import Foundation
import Testing

@testable import Prowl

/// An add/open and a reload share `CancelID.load`. These tests keep the add's `repoRoot` lookup
/// waiting so the add is really in flight when the reload arrives, which is what happens when
/// `prowl <path>` activates a background Prowl (#1032).
@MainActor
struct RepositoriesOpenReloadRaceTests {
  private let existingFolder = URL(fileURLWithPath: "/tmp/prowl-open-race/existing")
  private let otherFolder = URL(fileURLWithPath: "/tmp/prowl-open-race/other")
  private let newFolder = URL(fileURLWithPath: "/tmp/prowl-open-race/new")

  @Test func reloadDuringAnInFlightAddDoesNotCancelIt() async {
    let fixture = OpenRaceFixture(savedFolders: [existingFolder], heldFolder: newFolder)
    let store = fixture.makeStore(initialState: loadedState(folders: [existingFolder]))

    await store.send(.repositoryManagement(.openRepositories([newFolder]))) {
      $0.isOpeningRepositories = true
    }
    await fixture.heldLookup.waitUntilEntered()
    await store.send(.reloadRepositories(animated: false)) {
      $0.needsReloadAfterOpen = true
    }
    fixture.heldLookup.release()

    await store.receive(\.repositoryManagement.openRepositoriesFinished) {
      $0.isOpeningRepositories = false
      $0.needsReloadAfterOpen = false
      $0.repositoryRoots = [.local(existingFolder), .local(newFolder)]
    }
    await store.receive(\.reloadRepositories)
    await store.receive(\.repositoriesLoaded)
    await store.finish()

    #expect(fixture.savedPaths == [existingFolder, newFolder].map(Self.path))
    #expect(store.state.repositories.ids.contains(Self.path(newFolder)))
  }

  /// Several passive refreshes during one add run as a single reload after it.
  @Test func reloadsDuringAnAddRunOnceAfterIt() async {
    let fixture = OpenRaceFixture(savedFolders: [existingFolder], heldFolder: newFolder)
    let store = fixture.makeStore(initialState: loadedState(folders: [existingFolder]))

    await store.send(.repositoryManagement(.openRepositories([newFolder]))) {
      $0.isOpeningRepositories = true
    }
    await fixture.heldLookup.waitUntilEntered()
    await store.send(.reloadRepositories(animated: false)) {
      $0.needsReloadAfterOpen = true
    }
    await store.send(.refreshWorktrees) {
      $0.isRefreshingWorktrees = true
    }
    await store.receive(\.reloadRepositories)
    await store.send(.reloadRepositories(animated: true))
    fixture.heldLookup.release()

    await store.receive(\.repositoryManagement.openRepositoriesFinished) {
      $0.isOpeningRepositories = false
      $0.needsReloadAfterOpen = false
      $0.isRefreshingWorktrees = false
    }
    await store.receive(\.reloadRepositories)
    await store.receive(\.repositoriesLoaded)
    await store.finish()

    // One load for the add, one for the deferred reload.
    #expect(fixture.entryLoadCount == 2)
    #expect(fixture.savedPaths == [existingFolder, newFolder].map(Self.path))
  }

  /// A removal replaces the add with its own load. That load settles the add, so a later
  /// refresh is not swallowed by a stale in-flight flag.
  @Test func removalThatReplacesAnAddLetsLaterReloadsRun() async {
    let fixture = OpenRaceFixture(savedFolders: [existingFolder, otherFolder], heldFolder: newFolder)
    let store = fixture.makeStore(initialState: loadedState(folders: [existingFolder, otherFolder]))

    await store.send(.repositoryManagement(.openRepositories([newFolder]))) {
      $0.isOpeningRepositories = true
    }
    await fixture.heldLookup.waitUntilEntered()
    await store.send(.reloadRepositories(animated: false)) {
      $0.needsReloadAfterOpen = true
    }
    await store.send(
      .repositoryManagement(.repositoryRemoved(Self.path(existingFolder), selectionWasRemoved: false)))
    await store.receive(\.repositoriesLoaded) {
      $0.isOpeningRepositories = false
      $0.needsReloadAfterOpen = false
      $0.repositoryRoots = [.local(otherFolder)]
    }
    #expect(fixture.savedPaths == [Self.path(otherFolder)])

    let loadsBeforeReload = fixture.entryLoadCount
    await store.send(.reloadRepositories(animated: false))
    await store.receive(\.repositoriesLoaded)
    #expect(fixture.entryLoadCount == loadsBeforeReload + 1)

    // The cancelled add resumes only now; its result must not reach the store.
    fixture.heldLookup.release()
    await store.finish()
    #expect(store.state.repositoryRoots == [.local(otherFolder)])
  }

  private func loadedState(folders: [URL]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(
      uniqueElements: folders.map { folder in
        Repository(
          id: Self.path(folder),
          rootURL: folder,
          name: folder.lastPathComponent,
          kind: .plain,
          worktrees: []
        )
      })
    state.repositoryRoots = folders.map { .local($0) }
    state.isInitialLoadComplete = true
    state.snapshotPersistencePhase = .active
    return state
  }

  nonisolated static func path(_ url: URL) -> String {
    url.standardizedFileURL.path(percentEncoded: false)
  }
}

/// Saved project entries kept in memory, with plain folders only, and a `repoRoot` lookup for
/// one folder that waits until the test releases it.
final class OpenRaceFixture: Sendable {
  let heldLookup = HeldLookup()
  private let entries: LockIsolated<[PersistedRepositoryEntry]>
  private let entryLoads = LockIsolated(0)
  private let heldPath: String

  init(savedFolders: [URL], heldFolder: URL) {
    entries = LockIsolated(
      savedFolders.map { PersistedRepositoryEntry(path: RepositoriesOpenReloadRaceTests.path($0), kind: .plain) })
    heldPath = RepositoriesOpenReloadRaceTests.path(heldFolder)
  }

  var savedPaths: [String] { entries.value.map(\.path) }
  var entryLoadCount: Int { entryLoads.value }

  @MainActor
  func makeStore(initialState: RepositoriesFeature.State) -> TestStoreOf<RepositoriesFeature> {
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      apply(to: &$0)
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    store.timeout = .realWorkTestStoreTimeout
    return store
  }

  func apply(to dependencies: inout DependencyValues) {
    let entries = entries
    let entryLoads = entryLoads
    let heldPath = heldPath
    let heldLookup = heldLookup
    dependencies.repositoryPersistence.loadRepositoryEntries = {
      entryLoads.withValue { $0 += 1 }
      return entries.value
    }
    dependencies.repositoryPersistence.saveRepositoryEntries = { entries.setValue($0) }
    dependencies.repositoryPersistence.saveRepositorySnapshot = { _ in }
    dependencies.gitClient.repoRoot = { url in
      if RepositoriesOpenReloadRaceTests.path(url) == heldPath {
        await heldLookup.hold()
      }
      throw GitClientError.notRepository
    }
    dependencies.gitClient.worktrees = { root in
      Issue.record("worktrees should not load for a plain folder: \(root.path(percentEncoded: false))")
      return []
    }
  }
}

/// A lookup that waits until `release()`. Waiting ignores task cancellation, like a `git`
/// process that keeps running, so a cancelled add resumes only when the test releases it.
final class HeldLookup: Sendable {
  private struct Waiters {
    var isReleased = false
    var continuations: [CheckedContinuation<Void, Never>] = []
  }

  private let waiters = LockIsolated(Waiters())
  private let entered: AsyncStream<Void>
  private let enteredContinuation: AsyncStream<Void>.Continuation

  init() {
    (entered, enteredContinuation) = AsyncStream.makeStream()
  }

  func hold() async {
    await withCheckedContinuation { continuation in
      let isReleased = waiters.withValue { waiters in
        if !waiters.isReleased { waiters.continuations.append(continuation) }
        return waiters.isReleased
      }
      if isReleased { continuation.resume() }
      enteredContinuation.yield()
    }
  }

  /// Returns once a lookup is waiting.
  func waitUntilEntered() async {
    for await _ in entered { return }
  }

  /// Lets every waiting and later lookup through.
  func release() {
    let continuations = waiters.withValue { waiters in
      waiters.isReleased = true
      defer { waiters.continuations = [] }
      return waiters.continuations
    }
    for continuation in continuations { continuation.resume() }
  }
}
