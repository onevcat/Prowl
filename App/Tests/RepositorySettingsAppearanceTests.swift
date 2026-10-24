import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import Prowl

@MainActor
struct RepositorySettingsAppearanceTests {
  // MARK: - Helpers

  private func makeState(repositoryID: Repository.ID = "repo-1") -> RepositorySettingsFeature.State {
    RepositorySettingsFeature.State(
      location: .local(URL(fileURLWithPath: "/tmp/\(repositoryID)")),
      repositoryID: repositoryID,
      repositoryKind: .plain,
      settings: .default,
      userSettings: .default
    )
  }

  /// Seeds the shared appearances store before the pane is built, the
  /// way a previously saved appearance is on disk when Settings opens.
  private func makeStore(
    repositoryID: Repository.ID = "repo-1",
    initialAppearance: RepositoryAppearance = .empty,
    iconAssetStore: RepositoryIconAssetStore = .testNoOp,
    appearancesURL: URL = URL(fileURLWithPath: "/tmp/appearances-\(UUID().uuidString).json"),
    settingsStorage: SettingsTestStorage = SettingsTestStorage()
  ) -> TestStore<RepositorySettingsFeature.State, RepositorySettingsFeature.Action> {
    withDependencies {
      $0.settingsFileStorage = settingsStorage.storage
      $0.repositoryAppearancesFileURL = appearancesURL
      $0.repositoryIconAssetStore = iconAssetStore
    } operation: {
      if !initialAppearance.isEmpty {
        @Shared(.repositoryAppearances) var appearances
        $appearances.withLock { $0[repositoryID] = initialAppearance }
      }
      return TestStore(initialState: makeState(repositoryID: repositoryID)) {
        RepositorySettingsFeature()
      }
    }
  }

  // MARK: - Color

  @Test func setColorMutatesStateAndPersists() async throws {
    let appearancesURL = URL(fileURLWithPath: "/tmp/appearances-\(UUID().uuidString).json")
    let settingsStorage = SettingsTestStorage()
    let store = makeStore(appearancesURL: appearancesURL, settingsStorage: settingsStorage)

    await store.send(.setAppearanceColor(.blue)) {
      $0.$appearances.withLock { $0["repo-1"] = RepositoryAppearance(color: .blue) }
    }
    await store.finish()

    let persisted = readAppearances(at: appearancesURL, storage: settingsStorage)
    #expect(persisted["repo-1"]?.color == .blue)
  }

  @Test func setColorTwiceWithSameValueIsNoOp() async throws {
    let store = makeStore(initialAppearance: RepositoryAppearance(icon: nil, color: .red))
    await store.send(.setAppearanceColor(.red))
    await store.finish()
  }

  @Test func clearColorDropsEntryWhenIconAlsoNil() async throws {
    let appearancesURL = URL(fileURLWithPath: "/tmp/appearances-\(UUID().uuidString).json")
    let settingsStorage = SettingsTestStorage()
    let store = makeStore(
      initialAppearance: RepositoryAppearance(icon: nil, color: .green),
      appearancesURL: appearancesURL,
      settingsStorage: settingsStorage
    )

    await store.send(.setAppearanceColor(nil)) {
      $0.$appearances.withLock { $0["repo-1"] = nil }
    }
    await store.finish()

    let persisted = readAppearances(at: appearancesURL, storage: settingsStorage)
    #expect(persisted["repo-1"] == nil)
  }

  // MARK: - Icon

  @Test func setIconMutatesStateAndPersists() async throws {
    let appearancesURL = URL(fileURLWithPath: "/tmp/appearances-\(UUID().uuidString).json")
    let settingsStorage = SettingsTestStorage()
    let store = makeStore(appearancesURL: appearancesURL, settingsStorage: settingsStorage)

    await store.send(.setAppearanceIcon(.sfSymbol("folder.fill"))) {
      $0.$appearances.withLock { $0["repo-1"] = RepositoryAppearance(icon: .sfSymbol("folder.fill")) }
    }
    await store.finish()

    let persisted = readAppearances(at: appearancesURL, storage: settingsStorage)
    #expect(persisted["repo-1"]?.icon == .sfSymbol("folder.fill"))
  }

  @Test func clearingUserImageIconRemovesFileFromDisk() async throws {
    let removed = LockIsolated<[(String, URL)]>([])
    let store = makeStore(
      initialAppearance: RepositoryAppearance(
        icon: .userImage(filename: "old.png"), color: .blue
      ),
      iconAssetStore: .testRecording(removed: removed)
    )

    await store.send(.setAppearanceIcon(nil)) {
      $0.$appearances.withLock {
        $0["repo-1"] = RepositoryAppearance(color: .blue, iconDetectionSuppressed: true)
      }
    }
    await store.finish()

    #expect(removed.value.count == 1)
    #expect(removed.value.first?.0 == "old.png")
  }

  @Test func clearingDetectedIconRecordsSuppressionAndRemovesFile() async throws {
    let removed = LockIsolated<[(String, URL)]>([])
    let appearancesURL = URL(fileURLWithPath: "/tmp/appearances-\(UUID().uuidString).json")
    let settingsStorage = SettingsTestStorage()
    let store = makeStore(
      initialAppearance: RepositoryAppearance(
        icon: .detectedImage(filename: "detected.png"), color: nil
      ),
      iconAssetStore: .testRecording(removed: removed),
      appearancesURL: appearancesURL,
      settingsStorage: settingsStorage
    )

    await store.send(.setAppearanceIcon(nil)) {
      $0.$appearances.withLock { $0["repo-1"] = RepositoryAppearance(iconDetectionSuppressed: true) }
    }
    await store.finish()

    #expect(removed.value.first?.0 == "detected.png")
    // Suppression must survive persistence so a pending detection
    // can't restore the icon the user just cleared.
    let persisted = readAppearances(at: appearancesURL, storage: settingsStorage)
    #expect(persisted["repo-1"]?.iconDetectionSuppressed == true)
  }

  @Test func replacingDetectedIconWithManualOneRemovesDetectedFile() async throws {
    let removed = LockIsolated<[(String, URL)]>([])
    let store = makeStore(
      initialAppearance: RepositoryAppearance(
        icon: .detectedImage(filename: "detected.png"), color: nil
      ),
      iconAssetStore: .testRecording(removed: removed)
    )

    await store.send(.setAppearanceIcon(.sfSymbol("folder"))) {
      $0.$appearances.withLock { $0["repo-1"] = RepositoryAppearance(icon: .sfSymbol("folder")) }
    }
    await store.finish()

    #expect(removed.value.first?.0 == "detected.png")
  }

  @Test func replacingUserImageRemovesPreviousFile() async throws {
    let removed = LockIsolated<[(String, URL)]>([])
    let store = makeStore(
      initialAppearance: RepositoryAppearance(
        icon: .userImage(filename: "old.png"), color: nil
      ),
      iconAssetStore: .testRecording(removed: removed)
    )

    await store.send(.setAppearanceIcon(.sfSymbol("folder"))) {
      $0.$appearances.withLock { $0["repo-1"] = RepositoryAppearance(icon: .sfSymbol("folder")) }
    }
    await store.finish()

    #expect(removed.value.count == 1)
    #expect(removed.value.first?.0 == "old.png")
  }

  @Test func switchingFromSymbolToUserImageDoesNotTriggerRemoval() async throws {
    let removed = LockIsolated<[(String, URL)]>([])
    let store = makeStore(
      initialAppearance: RepositoryAppearance(icon: .sfSymbol("folder"), color: nil),
      iconAssetStore: .testRecording(removed: removed)
    )

    await store.send(.setAppearanceIcon(.userImage(filename: "new.png"))) {
      $0.$appearances.withLock { $0["repo-1"] = RepositoryAppearance(icon: .userImage(filename: "new.png")) }
    }
    await store.finish()

    #expect(removed.value.isEmpty)
  }

  @Test func sameUserImageReassignmentDoesNotTriggerRemoval() async throws {
    // Re-applying the same icon (e.g. an idempotent reducer flow) must
    // not delete the asset out from under the new state.
    let removed = LockIsolated<[(String, URL)]>([])
    let initial = RepositoryAppearance(
      icon: .userImage(filename: "stable.svg"), color: nil
    )
    let store = makeStore(initialAppearance: initial, iconAssetStore: .testRecording(removed: removed))

    await store.send(.setAppearanceIcon(.userImage(filename: "stable.svg")))
    await store.finish()

    #expect(removed.value.isEmpty)
  }

  // MARK: - Import

  @Test func importUserImageCommitsImportedIcon() async throws {
    let store = makeStore(
      iconAssetStore: RepositoryIconAssetStore(
        importImage: { _, _ in "abc.svg" },
        remove: { _, _ in },
        exists: { _, _ in true }
      )
    )

    // The effect commits into the shared store itself; no action comes back.
    store.exhaustivity = .off
    await store.send(.importUserImage(URL(fileURLWithPath: "/tmp/source.svg")))
    await store.finish()

    #expect(store.state.appearance == RepositoryAppearance(icon: .userImage(filename: "abc.svg")))
  }

  @Test func importGenericErrorSurfacesLocalizedDescription() async throws {
    struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
    let store = makeStore(
      iconAssetStore: RepositoryIconAssetStore(
        importImage: { _, _ in throw Boom() },
        remove: { _, _ in },
        exists: { _, _ in false }
      )
    )

    await store.send(.importUserImage(URL(fileURLWithPath: "/tmp/source.svg")))
    await store.receive(\.userImageImportFailed) {
      $0.appearanceImportError = "boom"
    }
    await store.finish()
  }

  @Test func dismissImportErrorClearsState() async throws {
    let store = makeStore()
    // Seed the error directly through the reducer surface.
    await store.send(.userImageImportFailed("boom")) {
      $0.appearanceImportError = "boom"
    }
    await store.send(.dismissAppearanceImportError) {
      $0.appearanceImportError = nil
    }
  }

  // MARK: - Reset

  @Test func resetAppearanceClearsBothAndRemovesUserImage() async throws {
    let removed = LockIsolated<[(String, URL)]>([])
    let appearancesURL = URL(fileURLWithPath: "/tmp/appearances-\(UUID().uuidString).json")
    let settingsStorage = SettingsTestStorage()
    let store = makeStore(
      initialAppearance: RepositoryAppearance(
        icon: .userImage(filename: "abc.png"), color: .blue
      ),
      iconAssetStore: .testRecording(removed: removed),
      appearancesURL: appearancesURL,
      settingsStorage: settingsStorage
    )

    await store.send(.resetAppearance) {
      // Reset removed an icon, so it records suppression like Clear.
      $0.$appearances.withLock { $0["repo-1"] = RepositoryAppearance(iconDetectionSuppressed: true) }
    }
    await store.finish()

    #expect(removed.value.first?.0 == "abc.png")
    let persisted = readAppearances(at: appearancesURL, storage: settingsStorage)
    #expect(persisted["repo-1"]?.iconDetectionSuppressed == true)
    #expect(persisted["repo-1"]?.icon == nil)
    #expect(persisted["repo-1"]?.color == nil)
  }

  @Test func resetAppearanceWithColorOnlyDoesNotSuppressDetection() async throws {
    let appearancesURL = URL(fileURLWithPath: "/tmp/appearances-\(UUID().uuidString).json")
    let settingsStorage = SettingsTestStorage()
    let store = makeStore(
      initialAppearance: RepositoryAppearance(icon: nil, color: .blue),
      appearancesURL: appearancesURL,
      settingsStorage: settingsStorage
    )

    await store.send(.resetAppearance) {
      $0.$appearances.withLock { $0["repo-1"] = nil }
    }
    await store.finish()

    let persisted = readAppearances(at: appearancesURL, storage: settingsStorage)
    #expect(persisted["repo-1"] == nil)
  }

  @Test func resetAppearanceWhenAlreadyEmptyIsNoOp() async throws {
    let removed = LockIsolated<[(String, URL)]>([])
    let store = makeStore(iconAssetStore: .testRecording(removed: removed))
    await store.send(.resetAppearance)
    await store.finish()
    #expect(removed.value.isEmpty)
  }

  // MARK: - Regression

  @Test func pickingColorKeepsExistingIcon() async throws {
    // Regression: appearance used to be loaded via `.task` async, which
    // raced with the first click after reopening Settings — picking a
    // color before `.task` finished would write `{icon: nil, color: x}`
    // and wipe the previously-saved icon. The pane now reads the shared
    // store directly, so the user's first click sees the right baseline.
    // This test pins that: with an icon already saved, setting a color
    // must preserve the icon.
    let store = makeStore(
      initialAppearance: RepositoryAppearance(icon: .sfSymbol("hammer.fill"), color: nil)
    )

    await store.send(.setAppearanceColor(.blue)) {
      $0.$appearances.withLock {
        $0["repo-1"] = RepositoryAppearance(icon: .sfSymbol("hammer.fill"), color: .blue)
      }
    }

    #expect(store.state.appearance.icon == .sfSymbol("hammer.fill"))
    #expect(store.state.appearance.color == .blue)
  }

  @Test func pickingIconKeepsExistingColor() async throws {
    // Mirror of the above for the symmetric case.
    let store = makeStore(
      initialAppearance: RepositoryAppearance(icon: nil, color: .red)
    )

    await store.send(.setAppearanceIcon(.sfSymbol("folder.fill"))) {
      $0.$appearances.withLock {
        $0["repo-1"] = RepositoryAppearance(icon: .sfSymbol("folder.fill"), color: .red)
      }
    }

    #expect(store.state.appearance.color == .red)
    #expect(store.state.appearance.icon == .sfSymbol("folder.fill"))
  }

  // MARK: - Concurrent writers (#624)

  /// Simulates automatic icon detection committing into the shared
  /// store after the Settings pane was built.
  private func landConcurrently(
    _ appearance: RepositoryAppearance,
    in store: TestStore<some Any, some Any>,
    for repositoryID: Repository.ID = "repo-1"
  ) {
    withDependencies {
      $0 = store.dependencies
    } operation: {
      @Shared(.repositoryAppearances) var appearances
      $appearances.withLock { $0[repositoryID] = appearance }
    }
  }

  private func storedAppearances(in store: TestStore<some Any, some Any>) -> [Repository.ID: RepositoryAppearance] {
    withDependencies {
      $0 = store.dependencies
    } operation: {
      @Shared(.repositoryAppearances) var appearances
      return appearances
    }
  }

  private func storedAppearances() -> [Repository.ID: RepositoryAppearance] {
    @Shared(.repositoryAppearances) var appearances
    return appearances
  }

  @Test(.dependencies) func colorChangeKeepsIconDetectedWhilePaneWasOpen() async throws {
    let removed = LockIsolated<[(String, URL)]>([])
    let appearancesURL = URL(fileURLWithPath: "/tmp/appearances-\(UUID().uuidString).json")
    let settingsStorage = SettingsTestStorage()
    let store = makeStore(
      iconAssetStore: .testRecording(removed: removed),
      appearancesURL: appearancesURL,
      settingsStorage: settingsStorage
    )
    store.exhaustivity = .off
    landConcurrently(RepositoryAppearance(icon: .detectedImage(filename: "detected.png")), in: store)

    await store.send(.setAppearanceColor(.blue))
    await store.finish()

    let expected = RepositoryAppearance(icon: .detectedImage(filename: "detected.png"), color: .blue)
    #expect(storedAppearances(in: store)["repo-1"] == expected)
    #expect(readAppearances(at: appearancesURL, storage: settingsStorage)["repo-1"] == expected)
    #expect(removed.value.isEmpty)
  }

  @Test(.dependencies) func colorChangeKeepsStoredDetectionSuppression() async throws {
    let store = makeStore()
    store.exhaustivity = .off
    landConcurrently(RepositoryAppearance(iconDetectionSuppressed: true), in: store)

    await store.send(.setAppearanceColor(.green))
    await store.finish()

    #expect(
      storedAppearances(in: store)["repo-1"] == RepositoryAppearance(color: .green, iconDetectionSuppressed: true))
  }

  @Test(.dependencies) func iconChangeRemovesIconDetectedWhilePaneWasOpen() async throws {
    let removed = LockIsolated<[(String, URL)]>([])
    let store = makeStore(iconAssetStore: .testRecording(removed: removed))
    store.exhaustivity = .off
    landConcurrently(RepositoryAppearance(icon: .detectedImage(filename: "detected.png"), color: .red), in: store)

    await store.send(.setAppearanceIcon(.sfSymbol("folder")))
    await store.finish()

    #expect(storedAppearances(in: store)["repo-1"] == RepositoryAppearance(icon: .sfSymbol("folder"), color: .red))
    #expect(removed.value.map(\.0) == ["detected.png"])
  }

  @Test(.dependencies) func resetRemovesIconDetectedWhilePaneWasOpen() async throws {
    let removed = LockIsolated<[(String, URL)]>([])
    let store = makeStore(iconAssetStore: .testRecording(removed: removed))
    store.exhaustivity = .off
    landConcurrently(RepositoryAppearance(icon: .detectedImage(filename: "detected.png")), in: store)

    await store.send(.resetAppearance)
    await store.finish()

    #expect(storedAppearances(in: store)["repo-1"] == RepositoryAppearance(iconDetectionSuppressed: true))
    #expect(removed.value.map(\.0) == ["detected.png"])
  }

  // MARK: - Synchronous persistence (#622)

  @Test(.dependencies) func appearanceEditsPersistInsideTheReducer() throws {
    // Reduce without running the returned effect: the shared write must
    // already be visible, so tearing the pane down (which may cancel or
    // orphan its effects) can never drop it.
    let settingsStorage = SettingsTestStorage()
    let appearancesURL = URL(fileURLWithPath: "/tmp/appearances-\(UUID().uuidString).json")
    withDependencies {
      $0.settingsFileStorage = settingsStorage.storage
      $0.repositoryAppearancesFileURL = appearancesURL
      $0.repositoryIconAssetStore = .testNoOp
    } operation: {
      var state = makeState()
      let feature = RepositorySettingsFeature()
      _ = feature._reduce(into: &state, action: .setAppearanceColor(.blue))
      #expect(storedAppearances()["repo-1"] == RepositoryAppearance(color: .blue))
      _ = feature._reduce(into: &state, action: .setAppearanceIcon(.sfSymbol("folder")))
      #expect(storedAppearances()["repo-1"] == RepositoryAppearance(icon: .sfSymbol("folder"), color: .blue))
      _ = feature._reduce(into: &state, action: .resetAppearance)
      #expect(storedAppearances()["repo-1"] == RepositoryAppearance(iconDetectionSuppressed: true))
    }
  }

  @Test(.dependencies) func userImageImportFinishingAfterPaneTeardownIsStillCommitted() async throws {
    // Deterministic ordering: `.send` effects are delivered synchronously
    // within the host action, while the import `.run` only starts once the
    // test yields (TestStore uses the main serial executor). So the pane is
    // gone before the import completes.
    let removed = LockIsolated<[(String, URL)]>([])
    let store = TestStore(
      initialState: PaneTeardownHost.State(
        pane: makeState())
    ) {
      PaneTeardownHost()
    } withDependencies: {
      $0.settingsFileStorage = SettingsTestStorage().storage
      $0.repositoryAppearancesFileURL = URL(fileURLWithPath: "/tmp/appearances-\(UUID().uuidString).json")
      $0.repositoryIconAssetStore = RepositoryIconAssetStore(
        importImage: { _, _ in "late.png" },
        remove: { filename, root in removed.withValue { $0.append((filename, root)) } },
        exists: { _, _ in true }
      )
    }
    store.exhaustivity = .off
    landConcurrently(RepositoryAppearance(icon: .detectedImage(filename: "detected.png")), in: store)

    await store.send(.importThenTeardown(URL(fileURLWithPath: "/tmp/source.png")))
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.pane == nil)
    #expect(storedAppearances(in: store)["repo-1"] == RepositoryAppearance(icon: .userImage(filename: "late.png")))
    // The replaced detected asset is cleaned up; the imported one is kept.
    #expect(removed.value.map(\.0) == ["detected.png"])
  }

  // MARK: - Persistence helpers

  private func readAppearances(
    at url: URL, storage: SettingsTestStorage
  ) -> [Repository.ID: RepositoryAppearance] {
    guard let data = try? storage.storage.load(url) else { return [:] }
    return (try? JSONDecoder().decode([Repository.ID: RepositoryAppearance].self, from: data))
      ?? [:]
  }
}

// MARK: - Test fixtures

/// Mirrors how `AppFeature` tears the repository pane down: the child
/// state is cleared by a sibling reducer that runs outside the `ifLet`,
/// so in-flight pane effects are neither cancelled nor able to deliver
/// actions back to the pane.
@Reducer
private struct PaneTeardownHost {
  @ObservableState
  struct State: Equatable {
    var pane: RepositorySettingsFeature.State?
  }

  enum Action {
    case importThenTeardown(URL)
    case teardown
    case pane(RepositorySettingsFeature.Action)
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .importThenTeardown(let url):
        return .merge(.send(.pane(.importUserImage(url))), .send(.teardown))
      case .teardown:
        state.pane = nil
        return .none
      case .pane:
        return .none
      }
    }
    Reduce<State, Action> { _, _ in .none }
      .ifLet(\.pane, action: \.pane) {
        RepositorySettingsFeature()
      }
  }
}

extension RepositoryIconAssetStore {
  /// Silent test fixture: import always returns an empty filename and
  /// remove/exists are no-ops. Use when the test doesn't care about
  /// either side's effects.
  fileprivate static let testNoOp = RepositoryIconAssetStore(
    importImage: { _, _ in "" },
    remove: { _, _ in },
    exists: { _, _ in false }
  )

  /// Test fixture that records every `remove` call so a test can
  /// assert on cleanup behavior without poking at the real
  /// filesystem.
  fileprivate static func testRecording(removed: LockIsolated<[(String, URL)]>)
    -> RepositoryIconAssetStore
  {
    RepositoryIconAssetStore(
      importImage: { _, _ in "" },
      remove: { filename, root in
        removed.withValue { $0.append((filename, root)) }
      },
      exists: { _, _ in false }
    )
  }
}
