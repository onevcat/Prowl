import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import ProwlCLIShared
import Sharing
import Testing

@testable import Prowl

/// Remote folders in the CLI: the `host` field, the selector, and the refusals that C2
/// makes reachable (docs-ai 084 C2).
@MainActor
struct CLIRemoteFolderTests {
  private static let profile = HostProfile(
    id: RemoteRepositoryFixtures.hostProfileID, alias: "mini", recipe: SSHConnectionRecipe(destination: "mini"),
    connectionKey: ConnectionKey(user: "dev", hostname: "mini.local"))

  private static func state() -> RepositoriesFeature.State {
    let localRoot = RepositoryLocation.local(URL(filePath: "/srv/app", directoryHint: .notDirectory))
    let local = Repository(
      location: localRoot, name: "app",
      worktrees: [Worktree(name: "main", detail: "", location: localRoot, repositoryLocation: localRoot)])
    let remote = RemoteRepositoryFixtures.gitRepository(path: "/srv/app", name: "app")
    var state = RepositoriesFeature.State()
    state.repositories = [local, remote]
    state.repositoryRoots = [local.location, remote.location]
    return state
  }

  /// A remote folder joins the CLI contexts with its host; a local worktree has none.
  @Test(.dependencies) func remoteFoldersJoinTheContextsWithTheirHost() throws {
    @Shared(.hostProfiles) var hostProfiles: [HostProfile]
    $hostProfiles.withLock { $0 = [Self.profile] }
    let contexts = ListRuntimeSnapshotBuilder.orderedWorktreeContexts(from: Self.state())

    #expect(contexts.map(\.path) == ["/srv/app", "/srv/app"])
    #expect(contexts[0].host == nil)
    let host = ListCommandHost(profileID: Self.profile.id.uuidString.lowercased(), label: "mini")
    #expect(contexts[1].host == host)
    #expect(contexts[1].listWorktree.displayPath == "mini:/srv/app")
    #expect(contexts[0].listWorktree.displayPath == "/srv/app")
  }

  /// The JSON payload gains `host` only for a remote folder.
  @Test func theHostFieldIsAdditive() throws {
    let local = ListCommandWorktree(id: "/srv/app", name: "main", path: "/srv/app", rootPath: "/srv/app", kind: .git)
    let remote = ListCommandWorktree(
      id: "ssh:x:/srv/app", name: "main", path: "/srv/app", rootPath: "/srv/app", kind: .git,
      host: ListCommandHost(profileID: "x", label: "mini"))
    let localJSON = try #require(String(data: JSONEncoder().encode(local), encoding: .utf8))
    let remoteJSON = try #require(String(data: JSONEncoder().encode(remote), encoding: .utf8))

    #expect(!localJSON.contains("host"))
    #expect(remoteJSON.contains(#""host":{"#))
    #expect(remoteJSON.contains(#""profile_id":"x""#))
    #expect(try JSONDecoder().decode(ListCommandWorktree.self, from: Data(remoteJSON.utf8)) == remote)
  }

  /// A bare path matches the local worktree only; `alias:/path` matches the remote one.
  @Test(.dependencies) func aBarePathMatchesLocalOnlyAndAliasPathMatchesRemote() {
    @Shared(.hostProfiles) var hostProfiles: [HostProfile]
    $hostProfiles.withLock { $0 = [Self.profile] }
    let contexts = ListRuntimeSnapshotBuilder.orderedWorktreeContexts(from: Self.state())
    let remoteID = RemoteRepositoryFixtures.location("/srv/app").id

    guard case .success(let local) = ProwlApp.resolveCLITabCreationTarget("/srv/app", worktrees: contexts) else {
      Issue.record("The bare path must match the local worktree")
      return
    }
    #expect(local.worktreeID == RepositoryLocation.local(URL(filePath: "/srv/app", directoryHint: .notDirectory)).id)
    guard case .success(let remote) = ProwlApp.resolveCLITabCreationTarget("mini:/srv/app", worktrees: contexts) else {
      Issue.record("alias:/path must match the remote worktree")
      return
    }
    #expect(remote.worktreeID == remoteID)
    // A name shared with a remote folder means the local worktree, which can open a tab.
    guard case .success(let named) = ProwlApp.resolveCLITabCreationTarget("main", worktrees: contexts) else {
      Issue.record("A shared name must resolve to the local worktree")
      return
    }
    #expect(named.worktreeID == local.worktreeID)
  }

  /// A selector that names a remote folder gets its reason instead of "not found".
  @Test func aRemoteFolderSelectorGetsItsReason() {
    let remote = ListRuntimeSnapshotBuilder.WorktreeContext(
      id: "ssh:x:/srv/app", name: "main", path: "/srv/app", rootPath: "/srv/app", kind: .git,
      host: ListCommandHost(profileID: "x", label: "mini"))
    let resolver = TargetResolver {
      TargetResolutionSnapshot(worktrees: [], focusedWorktreeID: nil, remoteFolders: [remote])
    }
    guard case .failure(.notFound(let message)) = resolver.resolve(.worktree("mini:/srv/app")) else {
      Issue.record("Expected a not-found failure")
      return
    }
    #expect(message.contains("remote folder"))
    guard case .failure(.notFound(let other)) = resolver.resolve(.worktree("/srv/app")) else {
      Issue.record("Expected a not-found failure")
      return
    }
    #expect(other == "Worktree '/srv/app' not found.")
    // A name could mean a local worktree without tabs, so it gets no remote reason.
    guard case .failure(.notFound(let named)) = resolver.resolve(.worktree("main")) else {
      Issue.record("Expected a not-found failure")
      return
    }
    #expect(named == "Worktree 'main' not found.")
    // `-t` keeps the reason for an exact name of the folder.
    for selector in ["mini:/srv/app", "ssh:x:/srv/app"] {
      guard case .failure(.notFound(let auto)) = resolver.resolve(.auto(selector)) else {
        Issue.record("Expected a not-found failure")
        return
      }
      #expect(auto.contains("remote folder"), "\(selector)")
    }
    guard case .failure(.notFound(let autoName)) = resolver.resolve(.auto("main")) else {
      Issue.record("Expected a not-found failure")
      return
    }
    #expect(autoName == "Target 'main' not found as pane, tab, or worktree.")
  }

  /// `create tab` in a remote folder opens a remote tab (docs-ai 084 C3c). Its path is a host
  /// path, checked by its text only: inside the folder it is kept as written (normalized, no
  /// `/private` from this Mac), outside it is refused before any creation.
  @Test func creatingATabInARemoteFolderChecksTheHostPath() async {
    let target = TabResolvedTarget(
      worktreeID: "ssh:5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42:/srv/app", worktreeName: "main", worktreePath: "/srv/app",
      worktreeRootPath: "/srv/app", worktreeKind: "git", tabID: "", tabTitle: "", tabSelected: false,
      paneID: "", paneTitle: "", paneCWD: nil, paneFocused: false)
    var paths: [String?] = []
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in .success(target) },
      resolveCloseTarget: { _ in .success(.init(resource: .pane, target: target)) },
      createTab: { _, path in
        paths.append(path)
        return target
      },
      createPane: { _, _ in nil },
      closeTab: { _, _ in false }, closePane: { _, _ in false })
    func create(_ path: String?) async -> CommandResponse {
      await handler.handle(
        envelope: .init(
          output: .json, command: .create(.init(resource: .tab, selector: .worktree("mini:/srv/app"), path: path))))
    }

    let outside = await create("/srv/app/../other")
    #expect(!outside.ok)
    #expect(outside.error?.code == CLIErrorCode.pathNotAllowed)
    #expect(await create(nil).ok)
    #expect(await create("/srv/app/./sub//dir/").ok)
    #expect(paths == [nil, "/srv/app/sub/dir"])
  }

  @Test func aHostPathIsNormalizedByItsTextOnly() {
    #expect(normalizedHostPath("/private/tmp/x/../y/./z//") == "/private/tmp/y/z")
    #expect(normalizedHostPath("/../a") == "/a")
    #expect(normalizedHostPath("/") == "/")
  }
}
