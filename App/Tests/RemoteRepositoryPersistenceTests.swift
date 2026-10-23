import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import Prowl

/// Persistence of remote folders (docs-ai 084 B2): `hosts.json`, remote entries and the
/// version 3 snapshot.
struct RemoteRepositoryPersistenceTests {
  private static let hostID = RemoteRepositoryFixtures.hostProfileID
  private static let hostsURL = URL(fileURLWithPath: "/tmp/prowl-hosts-tests.json")

  // MARK: - hosts.json

  @Test(.dependencies) func hostProfilesRoundTripThroughHostsJSON() throws {
    let storage = SettingsTestStorage()
    let profile = HostProfile(
      id: Self.hostID, alias: "mini", recipe: SSHConnectionRecipe(destination: "mini"),
      connectionKey: ConnectionKey(user: "dev", hostname: "mini.local"))

    let loaded: [HostProfile] = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.hostProfilesFileURL = Self.hostsURL
    } operation: {
      @Shared(.hostProfiles) var hosts: [HostProfile]
      #expect(hosts.isEmpty)
      $hosts.withLock { $0 = [profile] }
      return hosts
    }
    let data = try #require(try storage.storage.load(Self.hostsURL))
    let file = try JSONDecoder().decode(HostProfilesFile.self, from: data)

    #expect(loaded == [profile])
    #expect(file.version == 1)
    #expect(file.hosts == [profile])
  }

  @Test(.dependencies) func aHostsFileFromANewerBuildIsReadAsEmptyAndNeverOverwritten() throws {
    let storage = SettingsTestStorage()
    let newer = Data(#"{"version": 99, "hosts": [], "rebind": {}}"#.utf8)
    try storage.storage.save(newer, Self.hostsURL)

    withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.hostProfilesFileURL = Self.hostsURL
    } operation: {
      @Shared(.hostProfiles) var hosts: [HostProfile]
      #expect(hosts.isEmpty)
      $hosts.withLock { $0 = [] }
    }

    #expect(try storage.storage.load(Self.hostsURL) == newer)
  }

  @Test(.dependencies) func aHostsFileThatCannotBeReadIsNeverOverwritten() {
    let saves = LockIsolatedCounter()
    let storage = SettingsFileStorage(
      load: { _ in throw CocoaError(.fileReadNoPermission) },
      save: { _, _ in saves.increment() }
    )

    withDependencies {
      $0.settingsFileStorage = storage
      $0.hostProfilesFileURL = Self.hostsURL
    } operation: {
      @Shared(.hostProfiles) var hosts: [HostProfile]
      #expect(hosts.isEmpty)
      $hosts.withLock { $0 = [] }
      #expect($hosts.saveError != nil)
    }

    #expect(saves.value == 0)
  }

  // MARK: - Entries

  @Test func aRemoteEntryWritesItsHostAndDerivesItFromThePath() throws {
    let location = RemoteRepositoryFixtures.location("/srv/app")
    let entry = PersistedRepositoryEntry(path: location.id, kind: .git)
    let json = try #require(String(bytes: JSONEncoder().encode(entry), encoding: .utf8))
    // A stored host that disagrees with the path is ignored.
    let tampered = Data(#"{"path":"\#(location.id)","kind":"git","host":"00000000-0000-0000-0000-000000000000"}"#.utf8)

    #expect(entry.host == Self.hostID)
    #expect(json.contains(Self.hostID.uuidString))
    #expect(try JSONDecoder().decode(PersistedRepositoryEntry.self, from: tampered).host == Self.hostID)
  }

  @Test func aLocalEntryHasNoHostAndDecodesTheOldFormat() throws {
    let entry = try JSONDecoder().decode(
      PersistedRepositoryEntry.self, from: Data(#"{"path":"/tmp/repo","kind":"plain"}"#.utf8))
    let json = try #require(String(bytes: JSONEncoder().encode(entry), encoding: .utf8))

    #expect(entry == PersistedRepositoryEntry(path: "/tmp/repo", kind: .plain))
    #expect(entry.host == nil)
    #expect(!json.contains("host"))
  }

  // MARK: - Snapshot version 3

  @Test func aRemoteRepositoryRoundTripsWithoutAnyLocalPathCheck() {
    let remote = RemoteRepositoryFixtures.gitRepository()
    let payload = RepositorySnapshotCachePayload(repositories: [remote])

    let restored = payload.restoreRepositories { path in
      Issue.record("a remote path was checked on this Mac: \(path)")
      return false
    }

    #expect(payload.version == 3)
    #expect(restored == [remote])
  }

  @Test func aRemoteRepositoryNeverFailsTheSnapshotOnALocalPathCheck() {
    let kept = Self.localRepository("/tmp/prowl-kept")
    let remote = RemoteRepositoryFixtures.gitRepository()
    let payload = RepositorySnapshotCachePayload(repositories: [kept, remote])

    let restored = payload.restoreRepositories { $0.hasPrefix("/tmp/prowl-kept") }

    #expect(restored == [kept, remote])
  }

  /// A partial snapshot would prune the left-out repository's state on load, so a missing
  /// local repository still discards the whole snapshot, as in version 2.
  @Test func aMissingLocalRepositoryStillDiscardsTheWholeSnapshot() {
    let kept = Self.localRepository("/tmp/prowl-kept")
    let gone = Self.localRepository("/tmp/prowl-gone")
    let remote = RemoteRepositoryFixtures.gitRepository()
    let payload = RepositorySnapshotCachePayload(repositories: [kept, gone, remote])

    #expect(payload.restoreRepositories { !$0.hasPrefix("/tmp/prowl-gone") } == nil)
  }

  @Test func aRemoteWorktreeOnAnotherHostIsRejected() throws {
    let remote = RemoteRepositoryFixtures.location("/srv/app")
    let otherHost = RepositoryLocation.remote(hostProfileID: UUID(), path: "/srv/app-wt")
    let json = """
      {"version": 3, "repositories": [{"rootPath": "\(remote.id)", "name": "app", "kind": "git",
        "worktrees": [{"name": "wt", "detail": "", "workingDirectoryPath": "\(otherHost.id)"}]}]}
      """
    let payload = try JSONDecoder().decode(RepositorySnapshotCachePayload.self, from: Data(json.utf8))

    #expect(payload.restoreRepositories { _ in true } == nil)
  }

  @Test func aVersion2SnapshotStillRestoresItsLocalRepositories() throws {
    let json =
      #"{"version": 2, "repositories": [{"rootPath": "/tmp/repo", "name": "repo", "kind": "git", "worktrees": []}]}"#
    let payload = try JSONDecoder().decode(RepositorySnapshotCachePayload.self, from: Data(json.utf8))

    #expect(payload.restoreRepositories { _ in true }?.map(\.id) == ["/tmp/repo"])
  }

  private static func localRepository(_ path: String) -> Repository {
    let root = URL(fileURLWithPath: path)
    let main = Worktree(id: path, name: "main", detail: ".", workingDirectory: root, repositoryRootURL: root)
    return Repository(id: path, rootURL: root, name: root.lastPathComponent, worktrees: [main])
  }
}

private nonisolated final class LockIsolatedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}
