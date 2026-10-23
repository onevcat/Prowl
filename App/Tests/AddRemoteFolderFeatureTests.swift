import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import Prowl

/// The Add Remote Folder sheet (docs-ai 084 C1).
@MainActor
struct AddRemoteFolderFeatureTests {
  private static let profile = HostProfile(
    id: UUID(), alias: "mini", recipe: SSHConnectionRecipe(destination: "mini"),
    connectionKey: ConnectionKey(user: "dev", hostname: "mini.local"))

  @Test(.dependencies) func aNewHostIsSavedBeforeItsFolderIsAdded() async throws {
    let hostsURL = URL(fileURLWithPath: "/tmp/prowl-add-remote-\(UUID().uuidString).json")
    let storage = SettingsTestStorage()
    let newProfile = Self.profile
    let store = TestStore(initialState: AddRemoteFolderFeature.State(hostProfiles: [])) {
      AddRemoteFolderFeature()
    } withDependencies: {
      $0.settingsFileStorage = storage.storage
      $0.hostProfilesFileURL = hostsURL
      $0[RemoteFolderValidatorClient.self] = RemoteFolderValidatorClient(validate: { existing, destination, path, _ in
        #expect(existing == nil)
        #expect(destination == "mini")
        #expect(path == "~/app")
        return ValidatedRemoteFolder(profile: newProfile, isNewProfile: true, rootPath: "/home/dev/app", kind: .git)
      })
    }

    #expect(store.state.selectedProfile == nil)
    await store.send(\.binding.destination, "mini") { $0.destination = "mini" }
    await store.send(\.binding.path, "~/app") { $0.path = "~/app" }
    await store.send(.addButtonTapped) { $0.isValidating = true }
    await store.receive(\.validationFinished) { $0.isValidating = false }
    await store.receive(\.delegate.added)

    let file = try JSONDecoder().decode(HostProfilesFile.self, from: storage.storage.load(hostsURL))
    #expect(file.hosts == [newProfile])
  }

  @Test(.dependencies) func anExistingHostIsOfferedFirstAndAFailureShowsItsReason() async {
    let store = TestStore(initialState: AddRemoteFolderFeature.State(hostProfiles: [Self.profile])) {
      AddRemoteFolderFeature()
    } withDependencies: {
      $0[RemoteFolderValidatorClient.self] = RemoteFolderValidatorClient(validate: { existing, _, _, _ in
        #expect(existing?.id == Self.profile.id)
        throw RemoteFolderValidationError.folderNotFound("/srv/none")
      })
    }

    #expect(store.state.selectedProfileID == Self.profile.id)
    #expect(!store.state.canAdd)
    await store.send(\.binding.path, "/srv/none") { $0.path = "/srv/none" }
    #expect(store.state.canAdd)
    await store.send(.addButtonTapped) { $0.isValidating = true }
    await store.receive(\.validationFailed) {
      $0.isValidating = false
      $0.errorMessage = "There is no folder at /srv/none on the host."
    }
  }

  /// Cancel closes the sheet, except while the check runs: it stores a new host profile
  /// before it ends.
  @Test(.dependencies) func cancelClosesTheSheetExceptWhileTheCheckRuns() async {
    var validating = AddRemoteFolderFeature.State(hostProfiles: [])
    validating.isValidating = true
    let busy = TestStore(initialState: validating) {
      AddRemoteFolderFeature()
    }
    await busy.send(.cancelButtonTapped)

    let store = TestStore(initialState: AddRemoteFolderFeature.State(hostProfiles: [])) {
      AddRemoteFolderFeature()
    }
    await store.send(.cancelButtonTapped)
    await store.receive(\.delegate.cancel)
  }

  /// The sheet opens only while remote folders are on (`PROWL_REMOTE_FOLDERS=1`), with the
  /// newest host profile selected.
  @Test(.dependencies) func theSheetOpensOnlyWhileRemoteFoldersAreOn() async {
    #expect(!RemoteFolders.isEnabled(environment: [:]))
    #expect(RemoteFolders.isEnabled(environment: ["PROWL_REMOTE_FOLDERS": "1"]))
    let older = HostProfile(
      id: UUID(), alias: "old", recipe: SSHConnectionRecipe(destination: "old"),
      connectionKey: ConnectionKey(user: "dev", hostname: "old.local"))
    @Shared(.hostProfiles) var hostProfiles: [HostProfile]
    $hostProfiles.withLock { $0 = [older, Self.profile] }

    let disabled = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }
    await disabled.send(.addRemoteFolderRequested)

    let enabled = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0[RemoteFoldersEnabledKey.self] = true
    }
    await enabled.send(.addRemoteFolderRequested) {
      $0.addRemoteFolder = AddRemoteFolderFeature.State(hostProfiles: [older, Self.profile])
    }
    #expect(enabled.state.addRemoteFolder?.selectedProfileID == Self.profile.id)
  }

  /// A new destination with the same recipe as a known host reuses its profile; when its
  /// target changed, it needs a rebind instead of a second profile with the same name.
  @Test func aNewDestinationMatchesAKnownHostOrNeedsARebind() throws {
    let recipe = Self.profile.recipe
    #expect(
      try RemoteFolderValidatorClient.knownProfile(
        for: recipe, resolvedTo: Self.profile.connectionKey, in: [Self.profile])
        == Self.profile)
    #expect(
      try RemoteFolderValidatorClient.knownProfile(
        for: SSHConnectionRecipe(destination: "other"), resolvedTo: Self.profile.connectionKey, in: [Self.profile])
        == nil)
    #expect(throws: RemoteFolderValidationError.authorityChanged(alias: "mini")) {
      _ = try RemoteFolderValidatorClient.knownProfile(
        for: recipe, resolvedTo: ConnectionKey(user: "dev", hostname: "elsewhere.local"), in: [Self.profile])
    }
  }

  @Test func theKillSwitchStopsRemoteFolderConnections() {
    #expect(throws: RemoteRepositoryHostError.sideChannelDisabled) {
      try RemoteCommandLane.requireSideChannel(environment: ["PROWL_REMOTE_AGENT_DETECTION": "0"])
    }
    #expect(throws: Never.self) {
      try RemoteCommandLane.requireSideChannel(environment: ["PROWL_REMOTE_AGENT_DETECTION": "1"])
    }
  }

  /// A checked folder is added as an entry and loaded through its host.
  @Test(.dependencies) func anAddedFolderBecomesAnEntryAndLoads() async {
    let location = RemoteRepositoryFixtures.location("/home/dev/app")
    let saved = LockIsolated<[PersistedRepositoryEntry]>([])
    var state = RepositoriesFeature.State()
    state.addRemoteFolder = AddRemoteFolderFeature.State(hostProfiles: [])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = { [] }
      $0.repositoryPersistence.saveRepositoryEntries = { entries in saved.setValue(entries) }
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    await store.send(.addRemoteFolder(.presented(.delegate(.added(location, kind: .git))))) {
      $0.addRemoteFolder = nil
    }
    await store.receive(\.repositoryManagement.openRemoteRepository)
    await store.receive(\.repositoryManagement.openRepositoriesFinished, timeout: .seconds(10))

    #expect(saved.value == [PersistedRepositoryEntry(path: location.id, kind: .git)])
    #expect(store.state.repositoryRoots == [location])
    // Without a host connection in tests, it fails to load and stays listed as a failure.
    #expect(store.state.loadFailuresByID[location.id] != nil)
  }
}
