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
    } withDependencies: {
      $0[RemoteFoldersEnabledKey.self] = false
    }
    await disabled.send(.addRemoteFolderRequested)

    let enabled = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
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

  /// While remote folders are off, a stored remote folder stays stored but does not load,
  /// show or connect, and the prunes keep its pins, orders and archived worktrees.
  @Test(.dependencies) func aStoredRemoteFolderStaysHiddenAndKeptWhileTheFlagIsOff() async throws {
    let local = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "prowl-hidden-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: local) }
    // The stored form of a local folder ends in a slash.
    let localPath = PathPolicy.trimmingTrailingSlashes(local.path(percentEncoded: false)) + "/"
    let remote = RemoteRepositoryFixtures.location("/home/dev/app")
    let remoteWorktreeID = RemoteRepositoryFixtures.location("/home/dev/app-side").id
    let entries = [
      PersistedRepositoryEntry(path: localPath, kind: .plain),
      PersistedRepositoryEntry(path: remote.id, kind: .git),
    ]
    let saved = LockIsolated<[[PersistedRepositoryEntry]]>([])
    let hostCalls = LockIsolated(0)
    let snapshotRepository = Repository(
      location: remote, name: "app", kind: .git,
      worktrees: [
        Worktree(
          name: "side", detail: "",
          location: .remote(hostProfileID: RemoteRepositoryFixtures.hostProfileID, path: "/home/dev/app-side"),
          repositoryLocation: remote)
      ])
    var state = RepositoriesFeature.State()
    state.pinnedWorktreeIDs = [remoteWorktreeID]
    state.repositoryOrderIDs = [remote.id, localPath]
    state.worktreeOrderByRepository = [remote.id: [remoteWorktreeID]]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0[RemoteFoldersEnabledKey.self] = false
      $0.repositoryPersistence.loadRepositoryEntries = { entries }
      $0.repositoryPersistence.saveRepositoryEntries = { entries in saved.withValue { $0.append(entries) } }
      $0[RemoteRepositoryHostClient.self] = RemoteRepositoryHostClient(host: { _ in
        hostCalls.withValue { $0 += 1 }
        return nil
      })
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    await store.send(.repositorySnapshotLoaded([snapshotRepository]))
    #expect(store.state.repositories.isEmpty)
    await store.send(.loadPersistedRepositories)
    await store.receive(\.repositoriesLoaded, timeout: .seconds(10))

    #expect(store.state.repositories.map(\.id) == [localPath])
    #expect(store.state.repositoryRoots.map(\.id) == [localPath])
    #expect(store.state.loadFailuresByID.isEmpty)
    #expect(hostCalls.value == 0)
    #expect(store.state.pinnedWorktreeIDs == [remoteWorktreeID])
    #expect(store.state.repositoryOrderIDs == [remote.id, localPath])
    #expect(store.state.worktreeOrderByRepository == [remote.id: [remoteWorktreeID]])
    #expect(saved.value.allSatisfy { $0 == entries })
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

/// The live check behind the Add button, against a real SSH host when
/// `PROWL_REMOTE_LANE_HOST` names one. Skipped otherwise.
@MainActor
struct RemoteFolderValidatorLiveTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PROWL_REMOTE_LANE_HOST"] != nil))
  func aRealHostChecksAFolderForANewAndAKnownProfile() async throws {
    let hostName = try #require(ProcessInfo.processInfo.environment["PROWL_REMOTE_LANE_HOST"])
    let validate = RemoteFolderValidatorClient.liveValue.validate

    let added = try await validate(nil, hostName, "~", [])
    #expect(added.isNewProfile)
    #expect(added.profile.alias == hostName)
    #expect(added.rootPath.hasPrefix("/"))

    let again = try await validate(nil, hostName, "~", [added.profile])
    #expect(!again.isNewProfile)
    #expect(again.profile.id == added.profile.id)
    let known = try await validate(added.profile, "", "~", [added.profile])
    #expect(known.location == added.location)
    await #expect(throws: RemoteFolderValidationError.folderNotFound("/prowl-none-\(hostName)")) {
      _ = try await validate(added.profile, "", "/prowl-none-\(hostName)", [added.profile])
    }
  }
}
