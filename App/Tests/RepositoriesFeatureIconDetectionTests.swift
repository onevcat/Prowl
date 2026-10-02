import ComposableArchitecture
import Dependencies
import Foundation
import Sharing
import Testing

@testable import supacode

@MainActor
struct RepositoriesFeatureIconDetectionTests {
  // MARK: - Fixtures

  private func makeWorktree(id: String, name: String, repoRoot: String) -> Worktree {
    Worktree(
      id: id,
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: repoRoot),
      createdAt: nil
    )
  }

  private func makeRepository(
    id: String,
    name: String = "repo",
    kind: Repository.Kind = .git,
    worktrees: [Worktree] = [],
    workspace: ProjectWorkspace? = nil
  ) -> Repository {
    Repository(
      id: id,
      rootURL: URL(fileURLWithPath: id),
      name: name,
      kind: kind,
      worktrees: IdentifiedArray(uniqueElements: worktrees),
      workspace: workspace
    )
  }

  private func makeState(repositories: [Repository]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: repositories)
    state.repositoryRoots = repositories.map(\.rootURL)
    state.isInitialLoadComplete = true
    state.snapshotPersistencePhase = .active
    return state
  }

  private func recordingAssetStore(
    imported: LockIsolated<[URL]> = LockIsolated([]),
    removed: LockIsolated<[String]> = LockIsolated([]),
    importedFilename: String = "detected.png"
  ) -> RepositoryIconAssetStore {
    RepositoryIconAssetStore(
      importImage: { source, _ in
        imported.withValue { $0.append(source) }
        return importedFilename
      },
      remove: { filename, _ in
        removed.withValue { $0.append(filename) }
      },
      exists: { _, _ in true }
    )
  }

  private func appearances() -> [Repository.ID: RepositoryAppearance] {
    @Shared(.repositoryAppearances) var appearances
    return appearances
  }

  // MARK: - Spawn eligibility

  @Test func newRepositoryAfterInitialLoadIsScannedAndCommitted() async {
    let newRepo = makeRepository(id: "/tmp/new", name: "new", kind: .plain)
    let scanned = LockIsolated<[URL]>([])
    let store = TestStore(initialState: makeState(repositories: [])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryIconDetector.detect = { root in
        scanned.withValue { $0.append(root) }
        return RepositoryIconCandidate(
          imageURL: root.appending(path: "logo.png"),
          evidence: .webAsset
        )
      }
      $0.repositoryIconAssetStore = recordingAssetStore()
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repositoryWebURL = { _ in nil }
    }
    store.exhaustivity = .off

    await store.send(
      .repositoryManagement(
        .openRepositoriesFinished(
          [newRepo],
          failures: [],
          invalidRoots: [],
          openFailures: [],
          roots: [newRepo.rootURL]
        )
      )
    )
    await store.receive(\.repositoryManagement.repositoryIconDetected)
    await store.finish()

    #expect(scanned.value == [newRepo.rootURL])
    #expect(appearances()["/tmp/new"]?.icon == .detectedImage(filename: "detected.png"))
  }

  @Test func existingRepositoriesAreNotRescanned() async {
    let existing = makeRepository(id: "/tmp/existing", name: "existing")
    let scanned = LockIsolated<[URL]>([])
    let store = TestStore(initialState: makeState(repositories: [existing])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryIconDetector.detect = { root in
        scanned.withValue { $0.append(root) }
        return nil
      }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repositoryWebURL = { _ in nil }
    }
    store.exhaustivity = .off

    await store.send(
      .repositoryManagement(
        .openRepositoriesFinished(
          [existing],
          failures: [],
          invalidRoots: [],
          openFailures: [],
          roots: [existing.rootURL]
        )
      )
    )
    await store.finish()

    #expect(scanned.value.isEmpty)
  }

  @Test func disabledSettingPreventsScan() async {
    let newRepo = makeRepository(id: "/tmp/new", name: "new", kind: .plain)
    let scanned = LockIsolated<[URL]>([])
    let store = TestStore(initialState: makeState(repositories: [])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryIconDetector.detect = { root in
        scanned.withValue { $0.append(root) }
        return nil
      }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repositoryWebURL = { _ in nil }
    }
    store.exhaustivity = .off
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.detectRepositoryIconsAutomatically = false }

    await store.send(
      .repositoryManagement(
        .openRepositoriesFinished(
          [newRepo],
          failures: [],
          invalidRoots: [],
          openFailures: [],
          roots: [newRepo.rootURL]
        )
      )
    )
    await store.finish()

    #expect(scanned.value.isEmpty)
  }

  @Test func suppressedOrAlreadyIconedRepositoriesAreSkipped() async {
    let suppressed = makeRepository(id: "/tmp/suppressed", name: "suppressed", kind: .plain)
    let iconed = makeRepository(id: "/tmp/iconed", name: "iconed", kind: .plain)
    let fresh = makeRepository(id: "/tmp/fresh", name: "fresh", kind: .plain)
    let scanned = LockIsolated<[URL]>([])
    let store = TestStore(initialState: makeState(repositories: [])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryIconDetector.detect = { root in
        scanned.withValue { $0.append(root) }
        return nil
      }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repositoryWebURL = { _ in nil }
    }
    store.exhaustivity = .off
    @Shared(.repositoryAppearances) var shared
    $shared.withLock {
      $0["/tmp/suppressed"] = RepositoryAppearance(iconDetectionSuppressed: true)
      $0["/tmp/iconed"] = RepositoryAppearance(icon: .sfSymbol("folder"))
    }

    await store.send(
      .repositoryManagement(
        .openRepositoriesFinished(
          [suppressed, iconed, fresh],
          failures: [],
          invalidRoots: [],
          openFailures: [],
          roots: [suppressed.rootURL, iconed.rootURL, fresh.rootURL]
        )
      )
    )
    await store.finish()

    #expect(scanned.value == [fresh.rootURL])
  }

  // MARK: - Commit guards

  @Test func detectionResultCommitsForUntouchedRepository() async {
    let repo = makeRepository(id: "/tmp/repo", name: "repo", kind: .plain)
    let store = TestStore(initialState: makeState(repositories: [repo])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryIconAssetStore = recordingAssetStore()
    }

    await store.send(
      .repositoryManagement(.repositoryIconDetected("/tmp/repo", filename: "detected.png"))
    )
    await store.finish()

    #expect(appearances()["/tmp/repo"]?.icon == .detectedImage(filename: "detected.png"))
  }

  @Test func manualIconSetDuringScanDiscardsResult() async {
    let repo = makeRepository(id: "/tmp/repo", name: "repo", kind: .plain)
    let removed = LockIsolated<[String]>([])
    let store = TestStore(initialState: makeState(repositories: [repo])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryIconAssetStore = recordingAssetStore(removed: removed)
    }
    @Shared(.repositoryAppearances) var shared
    $shared.withLock {
      $0["/tmp/repo"] = RepositoryAppearance(icon: .sfSymbol("hammer"))
    }

    await store.send(
      .repositoryManagement(.repositoryIconDetected("/tmp/repo", filename: "detected.png"))
    )
    await store.finish()

    #expect(removed.value == ["detected.png"])
    #expect(appearances()["/tmp/repo"]?.icon == .sfSymbol("hammer"))
  }

  @Test func explicitClearDuringScanDiscardsResult() async {
    let repo = makeRepository(id: "/tmp/repo", name: "repo", kind: .plain)
    let removed = LockIsolated<[String]>([])
    let store = TestStore(initialState: makeState(repositories: [repo])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryIconAssetStore = recordingAssetStore(removed: removed)
    }
    @Shared(.repositoryAppearances) var shared
    $shared.withLock {
      $0["/tmp/repo"] = RepositoryAppearance(iconDetectionSuppressed: true)
    }

    await store.send(
      .repositoryManagement(.repositoryIconDetected("/tmp/repo", filename: "detected.png"))
    )
    await store.finish()

    #expect(removed.value == ["detected.png"])
    #expect(appearances()["/tmp/repo"]?.icon == nil)
  }

  @Test func removedRepositoryDiscardsResult() async {
    let removed = LockIsolated<[String]>([])
    let store = TestStore(initialState: makeState(repositories: [])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryIconAssetStore = recordingAssetStore(removed: removed)
    }

    await store.send(
      .repositoryManagement(.repositoryIconDetected("/tmp/gone", filename: "detected.png"))
    )
    await store.finish()

    #expect(removed.value == ["detected.png"])
    #expect(appearances()["/tmp/gone"] == nil)
  }

  @Test func disabledSettingAtCommitTimeDiscardsResult() async {
    let repo = makeRepository(id: "/tmp/repo", name: "repo", kind: .plain)
    let removed = LockIsolated<[String]>([])
    let store = TestStore(initialState: makeState(repositories: [repo])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryIconAssetStore = recordingAssetStore(removed: removed)
    }
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.detectRepositoryIconsAutomatically = false }

    await store.send(
      .repositoryManagement(.repositoryIconDetected("/tmp/repo", filename: "detected.png"))
    )
    await store.finish()

    #expect(removed.value == ["detected.png"])
    #expect(appearances()["/tmp/repo"] == nil)
  }

  @Test func commitPreservesExistingColor() async {
    let repo = makeRepository(id: "/tmp/repo", name: "repo", kind: .plain)
    let store = TestStore(initialState: makeState(repositories: [repo])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryIconAssetStore = recordingAssetStore()
    }
    @Shared(.repositoryAppearances) var shared
    $shared.withLock {
      $0["/tmp/repo"] = RepositoryAppearance(icon: nil, color: .blue)
    }

    await store.send(
      .repositoryManagement(.repositoryIconDetected("/tmp/repo", filename: "detected.png"))
    )
    await store.finish()

    #expect(appearances()["/tmp/repo"]?.icon == .detectedImage(filename: "detected.png"))
    #expect(appearances()["/tmp/repo"]?.color == .blue)
  }

  // MARK: - Removal cleanup

  @Test func repositoryRemovalCleansDetectedIconAndSuppressionButKeepsManualAppearance() async {
    let repo = makeRepository(id: "/tmp/repo", name: "repo", kind: .plain)
    let removed = LockIsolated<[String]>([])
    let store = TestStore(initialState: makeState(repositories: [repo])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryIconAssetStore = recordingAssetStore(removed: removed)
      $0.repositoryPersistence.loadRepositoryEntries = { [] }
      $0.repositoryPersistence.saveRepositoryEntries = { _ in }
    }
    store.exhaustivity = .off
    @Shared(.repositoryAppearances) var shared
    $shared.withLock {
      $0["/tmp/repo"] = RepositoryAppearance(
        icon: .detectedImage(filename: "detected.png"),
        color: .blue
      )
    }

    await store.send(
      .repositoryManagement(.repositoryRemoved("/tmp/repo", selectionWasRemoved: false))
    )
    await store.finish()

    #expect(removed.value == ["detected.png"])
    #expect(appearances()["/tmp/repo"]?.icon == nil)
    #expect(appearances()["/tmp/repo"]?.color == .blue)
    #expect(appearances()["/tmp/repo"]?.iconDetectionSuppressed == false)
  }

  @Test func repositoryRemovalClearsSuppressionOnlyEntryEntirely() async {
    let repo = makeRepository(id: "/tmp/repo", name: "repo", kind: .plain)
    let store = TestStore(initialState: makeState(repositories: [repo])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryIconAssetStore = recordingAssetStore()
      $0.repositoryPersistence.loadRepositoryEntries = { [] }
      $0.repositoryPersistence.saveRepositoryEntries = { _ in }
    }
    store.exhaustivity = .off
    @Shared(.repositoryAppearances) var shared
    $shared.withLock {
      $0["/tmp/repo"] = RepositoryAppearance(iconDetectionSuppressed: true)
    }

    await store.send(
      .repositoryManagement(.repositoryRemoved("/tmp/repo", selectionWasRemoved: false))
    )
    await store.finish()

    #expect(appearances()["/tmp/repo"] == nil)
  }

  @Test func repositoryRemovalKeepsManualUserImageUntouched() async {
    let repo = makeRepository(id: "/tmp/repo", name: "repo", kind: .plain)
    let removed = LockIsolated<[String]>([])
    let store = TestStore(initialState: makeState(repositories: [repo])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryIconAssetStore = recordingAssetStore(removed: removed)
      $0.repositoryPersistence.loadRepositoryEntries = { [] }
      $0.repositoryPersistence.saveRepositoryEntries = { _ in }
    }
    store.exhaustivity = .off
    @Shared(.repositoryAppearances) var shared
    $shared.withLock {
      $0["/tmp/repo"] = RepositoryAppearance(icon: .userImage(filename: "mine.png"))
    }

    await store.send(
      .repositoryManagement(.repositoryRemoved("/tmp/repo", selectionWasRemoved: false))
    )
    await store.finish()

    #expect(removed.value.isEmpty)
    #expect(appearances()["/tmp/repo"]?.icon == .userImage(filename: "mine.png"))
  }

  @Test func globalOptOutCancelsInFlightScans() async {
    let newRepo = makeRepository(id: "/tmp/new", name: "new", kind: .plain)
    let store = TestStore(initialState: makeState(repositories: [])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryIconDetector.detect = { _ in
        // Parks until cancelled, standing in for a long scan.
        let (stream, _) = AsyncStream<Never>.makeStream()
        for await _ in stream {}
        return nil
      }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repositoryWebURL = { _ in nil }
    }
    store.exhaustivity = .off

    await store.send(
      .repositoryManagement(
        .openRepositoriesFinished(
          [newRepo],
          failures: [],
          invalidRoots: [],
          openFailures: [],
          roots: [newRepo.rootURL]
        )
      )
    )
    await store.send(.repositoryManagement(.cancelPendingIconDetections))
    await store.finish()

    #expect(appearances()["/tmp/new"] == nil)
  }

  @Test func detectorOwnedTemporaryFileIsDeletedAfterImport() async throws {
    let temp = FileManager.default.temporaryDirectory
      .appending(path: "icon-composer-artifact-\(UUID().uuidString).png")
    try Data([0xDE, 0xAD]).write(to: temp)
    let newRepo = makeRepository(id: "/tmp/new", name: "new", kind: .plain)
    let store = TestStore(initialState: makeState(repositories: [])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryIconDetector.detect = { _ in
        RepositoryIconCandidate(
          imageURL: temp,
          evidence: .appleIconComposer,
          ownsImageFile: true
        )
      }
      $0.repositoryIconAssetStore = recordingAssetStore()
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repositoryWebURL = { _ in nil }
    }
    store.exhaustivity = .off

    await store.send(
      .repositoryManagement(
        .openRepositoriesFinished(
          [newRepo],
          failures: [],
          invalidRoots: [],
          openFailures: [],
          roots: [newRepo.rootURL]
        )
      )
    )
    await store.receive(\.repositoryManagement.repositoryIconDetected)
    await store.finish()

    #expect(!FileManager.default.fileExists(atPath: temp.path(percentEncoded: false)))
    #expect(appearances()["/tmp/new"]?.icon == .detectedImage(filename: "detected.png"))
  }

  // MARK: - Workspace exclusion

  @Test func workspaceContainersAreNeverScanned() async {
    let workspace = ProjectWorkspace(title: "WS")
    let container = makeRepository(
      id: "/tmp/workspace",
      name: "workspace",
      kind: .plain,
      workspace: workspace
    )
    let scanned = LockIsolated<[URL]>([])
    let store = TestStore(initialState: makeState(repositories: [])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryIconDetector.detect = { root in
        scanned.withValue { $0.append(root) }
        return nil
      }
      $0.repositoryPersistence.saveRepositorySnapshot = { _ in }
      $0.gitClient.repositoryWebURL = { _ in nil }
    }
    store.exhaustivity = .off

    await store.send(
      .repositoryManagement(
        .openRepositoriesFinished(
          [container],
          failures: [],
          invalidRoots: [],
          openFailures: [],
          roots: [container.rootURL]
        )
      )
    )
    await store.finish()

    #expect(scanned.value.isEmpty)
  }
}
