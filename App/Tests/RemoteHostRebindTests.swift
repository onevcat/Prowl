import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import Prowl

/// The unreachable state, the rebind of a changed host profile, and what removal does to
/// a remote folder's data (docs-ai 084 C1b).
@MainActor
struct RemoteHostRebindTests {
  private static let hostProfileID = RemoteRepositoryFixtures.hostProfileID
  private static let profile = HostProfile(
    id: hostProfileID, alias: "mini", recipe: SSHConnectionRecipe(destination: "mini"),
    connectionKey: ConnectionKey(user: "dev", hostname: "mini.local"))
  private static let moved = ConnectionKey(user: "dev", hostname: "mini-new.local", port: 2222)

  private static func failingHost(_ error: RemoteRepositoryHostError) -> RemoteRepositoryHostClient {
    let id = hostProfileID
    let remote = RemoteRepositoryHost(
      hostProfileID: id, lane: RemoteCommandLane(run: { _, _ in throw error }, runScript: { _, _ in throw error }))
    return RemoteRepositoryHostClient(host: { $0 == id ? remote : nil })
  }

  /// A load whose host profile now reaches another target fails with a rebind mark, and
  /// the sidebar row offers the rebind.
  @Test(.dependencies) func aLoadWithAChangedTargetAsksForARebind() async {
    let repository = RemoteRepositoryFixtures.gitRepository()
    let entry = PersistedRepositoryEntry(path: repository.id, kind: .git)
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRepositoryEntries = { [entry] }
      $0[RemoteRepositoryHostClient.self] = Self.failingHost(.authorityChanged)
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    await store.send(.loadPersistedRepositories)
    await store.receive(\.repositoriesLoaded, timeout: .seconds(10))

    #expect(store.state.rebindHostProfileIDs == [Self.hostProfileID])
    #expect(store.state.remoteHostStatus(for: repository.id) == .needsRebind(Self.hostProfileID))
    #expect(store.state.currentLoadFailures.map(\.authority) == [.changed])
    let row = store.state.sidebarPresentation(expandedRepositoryIDs: []).items.compactMap { item in
      if case .failedRepository(let model) = item { return model }
      return nil
    }
    #expect(row.map(\.hostStatus) == [.needsRebind(Self.hostProfileID)])

    // A failure for another reason passed the authority check, so the host is clear.
    await store.send(
      .repositoriesLoaded(
        [], failures: [.init(rootID: repository.id, message: "No answer", isHostUnreachable: true, authority: .passed)],
        roots: [repository.location], animated: false))
    #expect(store.state.rebindHostProfileIDs.isEmpty)
    #expect(store.state.remoteHostStatus(for: repository.id) == .unreachable)
  }

  /// An unreachable host shows as unreachable, and its row path is `alias:/path`.
  @Test(.dependencies) func anUnreachableHostShowsItsAliasAndPath() {
    @Shared(.hostProfiles) var hostProfiles: [HostProfile]
    $hostProfiles.withLock { $0 = [Self.profile] }
    let repository = RemoteRepositoryFixtures.gitRepository()
    var state = RepositoriesFeature.State()
    state.repositoryRoots = [repository.location]
    state.loadFailuresByID = [repository.id: "The remote host did not answer in time."]
    state.loadUnreachableRepositoryIDs = [repository.id]

    #expect(state.remoteHostStatus(for: repository.id) == .unreachable)
    let row = state.sidebarPresentation(expandedRepositoryIDs: []).items.compactMap { item in
      if case .failedRepository(let model) = item { return model }
      return nil
    }
    #expect(row.map(\.path) == ["mini:/home/dev/app"])
    #expect(row.map(\.hostStatus) == [.unreachable])
    #expect(state.remoteHostStatus(for: "/tmp/local/") == nil)
  }

  /// A poll that meets a changed target marks the host, and a good poll clears it.
  @Test(.dependencies) func aPollWithAChangedTargetMarksTheHostUntilAGoodPoll() async {
    let repository = RemoteRepositoryFixtures.gitRepository()
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    state.remoteRefreshRepositoryIDs = [repository.id]
    state.remoteRefreshInFlightIDs = [repository.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    await store.send(
      .remoteRepositoryRefreshed(
        repository.id, .failed(message: "changed", isHostUnreachable: false, authority: .changed)))
    #expect(store.state.rebindHostProfileIDs == [Self.hostProfileID])
    #expect(store.state.remoteHostStatus(for: repository.id) == .needsRebind(Self.hostProfileID))

    await store.send(
      .remoteRepositoryRefreshed(repository.id, .failed(message: "other", isHostUnreachable: false)))
    #expect(store.state.rebindHostProfileIDs.isEmpty)
    #expect(store.state.remoteHostStatus(for: repository.id) == nil)
  }

  /// The rebind shows the new target, stores it in the host profile, and connects the
  /// host's folders again: a poll in flight with the old target is cancelled, the backoff
  /// ends, the holds start again, and the folders poll and reload at once.
  @Test(.dependencies) func aRebindStoresTheNewTargetAndConnectsAgain() async throws {
    let hostsURL = URL(fileURLWithPath: "/tmp/prowl-rebind-\(UUID().uuidString).json")
    let storage = SettingsTestStorage()
    let repository = RemoteRepositoryFixtures.gitRepository()
    let (holds, held) = AsyncStream<Void>.makeStream()
    var client = RemoteRepositoryHostClient(host: { _ in nil })
    client.holdConnection = { _ in
      held.yield()
      return RemoteConnectionHold(release: {})
    }
    let target = RemoteHostTarget(profile: Self.profile, resolved: Self.moved)
    client.resolveTarget = { _ in target }
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    state.repositoryRoots = [repository.location]
    state.remoteRefreshRepositoryIDs = [repository.id]
    state.remoteRefreshInFlightIDs = [repository.id]
    state.remoteRefreshFailureCounts = [repository.id: 3]
    state.rebindHostProfileIDs = [Self.hostProfileID]
    try storage.storage.save(JSONEncoder().encode(HostProfilesFile(hosts: [Self.profile])), hostsURL)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.settingsFileStorage = storage.storage
      $0.hostProfilesFileURL = hostsURL
      $0[RemoteRepositoryHostClient.self] = client
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    await store.send(.remoteHostRebindRequested(Self.hostProfileID))
    await store.receive(\.remoteHostRebindResolved)
    #expect(store.state.alert == RepositoriesFeature().rebindAlert(for: target))

    await store.send(.alert(.presented(.rebindRemoteHost(Self.hostProfileID, Self.moved)))) {
      $0.alert = nil
    }
    await store.receive(\.remoteHostRebound) {
      $0.rebindHostProfileIDs = []
      $0.remoteRefreshFailureCounts = [:]
    }
    await store.receive(\.reloadRepositories)
    await store.receive(\.remoteRepositoryRefreshDue)
    var heldIterator = holds.makeAsyncIterator()
    await heldIterator.next()

    let file = try JSONDecoder().decode(HostProfilesFile.self, from: storage.storage.load(hostsURL))
    #expect(file.hosts.map(\.connectionKey) == [Self.moved])
  }

  /// A hosts file that changed since it was loaded is read again, and the new target is
  /// stored in it; an unreadable file is not written and the rebind stops with its reason.
  @Test(.dependencies) func aRebindReadsAChangedHostsFileAgain() async throws {
    let hostsURL = URL(fileURLWithPath: "/tmp/prowl-rebind-\(UUID().uuidString).json")
    let storage = SettingsTestStorage()
    let other = HostProfile(
      id: UUID(), alias: "box", recipe: SSHConnectionRecipe(destination: "box"),
      connectionKey: ConnectionKey(user: "dev", hostname: "box.local"))
    try storage.storage.save(JSONEncoder().encode(HostProfilesFile(hosts: [Self.profile])), hostsURL)
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.settingsFileStorage = storage.storage
      $0.hostProfilesFileURL = hostsURL
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    let first = ConnectionKey(user: "dev", hostname: "first.local")
    await store.send(.alert(.presented(.rebindRemoteHost(Self.hostProfileID, first))))
    await store.receive(\.remoteHostRebound)
    var changed = Self.profile
    changed.connectionKey = first
    try storage.storage.save(JSONEncoder().encode(HostProfilesFile(hosts: [changed, other])), hostsURL)

    await store.send(.alert(.presented(.rebindRemoteHost(Self.hostProfileID, Self.moved))))
    await store.receive(\.remoteHostRebound)
    let file = try JSONDecoder().decode(HostProfilesFile.self, from: storage.storage.load(hostsURL))
    #expect(file.hosts.map(\.id) == [Self.hostProfileID, other.id])
    #expect(file.hosts.first?.connectionKey == Self.moved)

    try storage.storage.save(Data("{\"version\": 99}".utf8), hostsURL)
    await store.send(.alert(.presented(.rebindRemoteHost(Self.hostProfileID, first))))
    await store.receive(\.remoteHostRebindFailed)
    #expect(store.state.alert?.title == TextState("Prowl could not rebind the host"))
    #expect(try storage.storage.load(hostsURL) == Data("{\"version\": 99}".utf8))
  }

  /// The add sheet offers the rebind when a known host's target changed: it stores the new
  /// target, tells the sidebar, and adds the folder.
  @Test(.dependencies) func theAddSheetRebindsAChangedHostAndAddsTheFolder() async throws {
    let hostsURL = URL(fileURLWithPath: "/tmp/prowl-rebind-\(UUID().uuidString).json")
    let storage = SettingsTestStorage()
    try storage.storage.save(JSONEncoder().encode(HostProfilesFile(hosts: [Self.profile])), hostsURL)
    let moved = Self.moved
    let store = TestStore(initialState: AddRemoteFolderFeature.State(hostProfiles: [Self.profile])) {
      AddRemoteFolderFeature()
    } withDependencies: {
      $0.settingsFileStorage = storage.storage
      $0.hostProfilesFileURL = hostsURL
      $0[RemoteFolderValidatorClient.self] = RemoteFolderValidatorClient(validate: { existing, _, _, _ in
        let existing = try #require(existing)
        guard existing.connectionKey == moved else {
          throw RemoteFolderValidationError.authorityChanged(existing, resolved: moved)
        }
        return ValidatedRemoteFolder(profile: existing, isNewProfile: false, rootPath: "/home/dev/app", kind: .git)
      })
    }
    let target = RemoteHostTarget(profile: Self.profile, resolved: Self.moved)

    await store.send(\.binding.path, "~/app") { $0.path = "~/app" }
    await store.send(.addButtonTapped) { $0.isValidating = true }
    await store.receive(\.validationNeedsRebind) {
      $0.isValidating = false
      $0.pendingRebind = target
      $0.errorMessage = RemoteFolderValidationError.authorityChanged(Self.profile, resolved: moved).localizedDescription
    }
    await store.send(.rebindButtonTapped) { $0.isValidating = true }
    await store.receive(\.rebound) {
      $0.isValidating = false
      $0.pendingRebind = nil
      $0.hostProfiles[0].connectionKey = moved
    }
    await store.receive(\.delegate.hostRebound)
    await store.receive(\.addButtonTapped) {
      $0.isValidating = true
      $0.errorMessage = nil
    }
    await store.receive(\.validationFinished) { $0.isValidating = false }
    await store.receive(\.delegate.added)
    let file = try JSONDecoder().decode(HostProfilesFile.self, from: storage.storage.load(hostsURL))
    #expect(file.hosts.map(\.connectionKey) == [moved])
  }

  /// A poll or a load that finds a changed target ends the holds on that host, which hold
  /// a connection to the old target; another host keeps its hold. The time limit turns a
  /// hold that never ends into a failure instead of a hang.
  @Test(.dependencies, .timeLimit(.minutes(1))) func aChangedTargetEndsTheHoldsOnItsHost() async {
    let first = RemoteRepositoryFixtures.gitRepository(path: "/home/dev/a", name: "a")
    let second = RemoteRepositoryFixtures.gitRepository(path: "/home/dev/b", name: "b")
    let otherHost = UUID()
    let otherRoot = RepositoryLocation.remote(hostProfileID: otherHost, path: "/srv/c")
    let other = Repository(
      location: otherRoot, name: "c",
      worktrees: [Worktree(name: "main", detail: "", location: otherRoot, repositoryLocation: otherRoot)])
    let (holds, held) = AsyncStream<UUID>.makeStream()
    let (releases, released) = AsyncStream<UUID>.makeStream()
    var client = RemoteRepositoryHostClient(host: { _ in nil })
    client.holdConnection = { hostProfileID in
      held.yield(hostProfileID)
      return RemoteConnectionHold(release: { released.yield(hostProfileID) })
    }
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0[RemoteRepositoryHostClient.self] = client
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    let repositories = [first, second, other]
    await store.send(
      .repositoriesLoaded(repositories, failures: [], roots: repositories.map(\.location), animated: false))
    var heldIterator = holds.makeAsyncIterator()
    for _ in 0..<3 { _ = await heldIterator.next() }

    await store.send(
      .remoteRepositoryRefreshed(first.id, .failed(message: "changed", isHostUnreachable: false, authority: .changed)))
    var releasedIterator = releases.makeAsyncIterator()
    let ended = [await releasedIterator.next(), await releasedIterator.next()]
    #expect(ended == [Self.hostProfileID, Self.hostProfileID])
    #expect(store.state.rebindHostProfileIDs == [Self.hostProfileID])

    // A configuration that `ssh -G` rejects says nothing about the target: the mark stays.
    await store.send(
      .remoteRepositoryRefreshed(
        first.id,
        .failed(
          message: "rejected", isHostUnreachable: false,
          authority: RemoteAuthorityCheck(
            RemoteRepositoryHostError.configurationRejected))))
    #expect(store.state.rebindHostProfileIDs == [Self.hostProfileID])

    // The configuration reaches the bound target again: a good poll clears the mark and
    // holds the host's connection again, without a rebind.
    await store.send(
      .remoteRepositoryRefreshed(first.id, .failed(message: "no answer", isHostUnreachable: true)))
    #expect(store.state.rebindHostProfileIDs.isEmpty)
    let again = [await heldIterator.next(), await heldIterator.next()]
    #expect(again == [Self.hostProfileID, Self.hostProfileID])

    // A load that finds a changed target ends the holds of that host too.
    await store.send(
      .repositoriesLoaded(
        [other], failures: [.init(rootID: other.id, message: "changed", authority: .changed)],
        roots: [otherRoot], animated: false))
    // The two folders that left end their holds too, in any order.
    var rest: [UUID?] = []
    for _ in 0..<3 { rest.append(await releasedIterator.next()) }
    #expect(rest.filter { $0 == otherHost }.count == 1)
    await store.send(.repositoriesLoaded([], failures: [], roots: [], animated: false))
    await store.finish(timeout: .seconds(10))
  }

  /// Removing a remote folder from its failed row says first what happens to its data; a
  /// local failed repository is removed at once.
  @Test(.dependencies) func aFailedRemoteFolderAsksBeforeItIsRemoved() async {
    @Shared(.hostProfiles) var hostProfiles: [HostProfile]
    $hostProfiles.withLock { $0 = [Self.profile] }
    let remote = RemoteRepositoryFixtures.location("/home/dev/app")
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }
    store.exhaustivity = .off

    await store.send(.repositoryManagement(.requestRemoveFailedRepository(remote.id)))
    let message = store.state.alert.map { String(describing: $0.message) } ?? ""
    #expect(message.contains("files on mini stay as they are"))
    await store.send(.alert(.presented(.confirmRemoveFailedRepository(remote.id))))
    await store.receive(\.repositoryManagement.removeFailedRepository)
    // Its saved terminal layout goes too (docs-ai 084 C5).
    await store.finish(timeout: .seconds(10))
    #expect(sent.value.contains(.discardSavedLayout(repositoryID: remote.id)))

    await store.send(.repositoryManagement(.requestRemoveFailedRepository("/tmp/local/")))
    await store.receive(\.repositoryManagement.removeFailedRepository)
  }

  @Test func aFailureBeforeTheAuthorityCheckSaysNothingAboutTheTarget() {
    #expect(RemoteAuthorityCheck(RemoteRepositoryHostError.authorityChanged) == .changed)
    for error: any Error in [
      RemoteRepositoryHostError.configurationRejected, RemoteRepositoryHostError.sideChannelDisabled,
      RemoteRepositoryHostError.bundledScriptMissing, RepositoryHostError.hostProfileMissing(UUID()),
    ] {
      #expect(RemoteAuthorityCheck(error) == .unknown, "\(error)")
    }
    #expect(RemoteAuthorityCheck(RemoteRepositoryHostError.timedOut) == .passed)
    #expect(RemoteAuthorityCheck(RemoteRepositoryHostError.gitMissing) == .passed)
  }

  @Test func theRebindPromptNamesBothTargets() {
    let alert = RepositoriesFeature().rebindAlert(
      for: RemoteHostTarget(profile: Self.profile, resolved: Self.moved))
    #expect(String(describing: alert.message).contains("dev@mini-new.local:2222"))
    #expect(String(describing: alert.message).contains("dev@mini.local"))
    #expect(Self.moved.displayName == "dev@mini-new.local:2222")
    #expect(Self.profile.connectionKey.displayName == "dev@mini.local")
  }

  /// Removing a remote folder says that its files stay on the host and the host stays.
  @Test(.dependencies) func removingARemoteFolderSaysWhatHappensToItsData() {
    @Shared(.hostProfiles) var hostProfiles: [HostProfile]
    $hostProfiles.withLock { $0 = [Self.profile] }
    let message = RepositoriesFeature.removalMessage(for: RemoteRepositoryFixtures.location("/home/dev/app"))
    #expect(message.contains("files on mini stay as they are"))
    #expect(message.contains("mini stays in the host list"))
    #expect(
      RepositoriesFeature.removalMessage(for: .remote(hostProfileID: UUID(), path: "/srv/app"))
        == "This removes the folder from Prowl. Its worktrees and files on its host stay as they are.")
    #expect(
      RepositoriesFeature.removalMessage(for: .local(URL(filePath: "/tmp/app/")))
        == "This removes the repository from Prowl. Worktrees and the main repository folder stay on disk.")
  }
}
