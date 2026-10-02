import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

@MainActor
struct RepositorySettingsAppearanceTests {
  // MARK: - Helpers

  private func makeStore(
    repositoryID: Repository.ID = "repo-1",
    initialAppearance: RepositoryAppearance = .empty,
    iconAssetStore: RepositoryIconAssetStore = .testNoOp,
    appearancesURL: URL = URL(fileURLWithPath: "/tmp/appearances-\(UUID().uuidString).json"),
    settingsStorage: SettingsTestStorage = SettingsTestStorage()
  ) -> TestStore<RepositorySettingsFeature.State, RepositorySettingsFeature.Action> {
    TestStore(
      initialState: RepositorySettingsFeature.State(
        rootURL: URL(fileURLWithPath: "/tmp/\(repositoryID)"),
        repositoryID: repositoryID,
        repositoryKind: .plain,
        settings: .default,
        userSettings: .default,
        appearance: initialAppearance
      )
    ) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.settingsFileStorage = settingsStorage.storage
      $0.repositoryAppearancesFileURL = appearancesURL
      $0.repositoryIconAssetStore = iconAssetStore
    }
  }

  // MARK: - Color

  @Test func setColorMutatesStateAndPersists() async throws {
    let appearancesURL = URL(fileURLWithPath: "/tmp/appearances-\(UUID().uuidString).json")
    let settingsStorage = SettingsTestStorage()
    let store = makeStore(appearancesURL: appearancesURL, settingsStorage: settingsStorage)

    await store.send(.setAppearanceColor(.blue)) {
      $0.appearance.color = .blue
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
      $0.appearance.color = nil
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
      $0.appearance.icon = .sfSymbol("folder.fill")
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
      $0.appearance.icon = nil
      $0.appearance.iconDetectionSuppressed = true
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
      $0.appearance.icon = nil
      $0.appearance.iconDetectionSuppressed = true
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
      $0.appearance.icon = .sfSymbol("folder")
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
      $0.appearance.icon = .sfSymbol("folder")
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
      $0.appearance.icon = .userImage(filename: "new.png")
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

  @Test func importUserImageDispatchesImportedAction() async throws {
    let store = makeStore(
      iconAssetStore: RepositoryIconAssetStore(
        importImage: { _, _ in "abc.svg" },
        remove: { _, _ in },
        exists: { _, _ in true }
      )
    )

    await store.send(.importUserImage(URL(fileURLWithPath: "/tmp/source.svg")))
    await store.receive(\.userImageImported) { _ in
      // payload check below
    }
    await store.receive(\.setAppearanceIcon) {
      $0.appearance.icon = .userImage(filename: "abc.svg")
    }
    await store.finish()
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
      $0.appearance = RepositoryAppearance(iconDetectionSuppressed: true)
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
      $0.appearance = .empty
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

  // MARK: - appearanceLoaded

  @Test func appearanceLoadedReplacesState() async throws {
    let store = makeStore()
    let loaded = RepositoryAppearance(icon: .sfSymbol("hammer"), color: .purple)
    await store.send(.appearanceLoaded(loaded)) {
      $0.appearance = loaded
    }
  }

  // MARK: - Regression

  @Test func pickingColorKeepsExistingIcon() async throws {
    // Regression: appearance used to be loaded via `.task` async, which
    // raced with the first click after reopening Settings — picking a
    // color before `.task` finished would write `{icon: nil, color: x}`
    // and wipe the previously-saved icon. The fix seeds appearance
    // synchronously when the State is built, so the user's first click
    // sees the right baseline. This test pins the new behavior: with
    // an icon pre-set in initial state, setting a color must preserve
    // the icon.
    let store = makeStore(
      initialAppearance: RepositoryAppearance(icon: .sfSymbol("hammer.fill"), color: nil)
    )

    await store.send(.setAppearanceColor(.blue)) {
      $0.appearance.color = .blue
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
      $0.appearance.icon = .sfSymbol("folder.fill")
    }

    #expect(store.state.appearance.color == .red)
    #expect(store.state.appearance.icon == .sfSymbol("folder.fill"))
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
