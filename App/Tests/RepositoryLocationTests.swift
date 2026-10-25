import Foundation
import IdentifiedCollections
import Testing

@testable import Prowl

struct RepositoryLocationTests {
  private let hostProfileID = UUID(uuidString: "5C1F0A8E-7D1B-4C63-9A3E-2F1B6C9D0E42")!

  @Test func localIDIsTheURLPathUnchanged() {
    let directory = URL(fileURLWithPath: "/tmp/work/app/", isDirectory: true)
    let file = URL(fileURLWithPath: "/tmp/work/app", isDirectory: false)

    #expect(RepositoryLocation.local(directory).id == directory.path(percentEncoded: false))
    #expect(RepositoryLocation.local(directory).id == "/tmp/work/app/")
    #expect(RepositoryLocation.local(file).id == "/tmp/work/app")
  }

  @Test func remoteIDUsesLowercaseProfileAndRawPath() {
    let location = RepositoryLocation.remote(hostProfileID: hostProfileID, path: "/home/dev/src/app")

    #expect(location.id == "ssh:5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42:/home/dev/src/app")
  }

  @Test(arguments: [
    "/home/dev/src/app",
    "/home/dev/my app",
    "/home/dev/100%/done",
    "/home/dev/issue#12",
    "/home/dev/a:b:c",
    "/home/dev/日本語/プロジェクト",
    "/home/dev/emoji 🐱",
    "/",
  ])
  func remoteIDRoundTripsHostilePaths(path: String) {
    let location = RepositoryLocation.remote(hostProfileID: hostProfileID, path: path)

    #expect(RepositoryLocation(id: location.id) == location)
  }

  @Test(arguments: [
    "/tmp/work/app",
    "/tmp/work/app/",
    "/tmp/work/my app",
    "/tmp/work/100%",
    "/tmp/work/issue#12",
    "/tmp/work/a:b",
    "/tmp/work/日本語",
  ])
  func localIDRoundTripsByteForByte(id: String) {
    let decoded = RepositoryLocation(id: id)

    #expect(decoded?.id == id)
    #expect(decoded?.localURL?.path(percentEncoded: false) == id)
  }

  @Test(arguments: [
    "",
    "relative/path",
    "~/src/app",
    "ssh:",
    "ssh:5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42",
    "ssh:5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42:",
    "ssh:5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42:relative",
    "ssh:5C1F0A8E-7D1B-4C63-9A3E-2F1B6C9D0E42:/home/dev",
    "ssh:not-a-uuid-not-a-uuid-not-a-uuid-xx:/home/dev",
    "remote:5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42:/home/dev",
    "ssh:5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42:/home/dev/",
    "ssh:5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42:/home//dev",
    "ssh:5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42:/home/./dev",
    "ssh:5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42:/home/dev/..",
  ])
  func rejectsStringsInNeitherForm(id: String) {
    #expect(RepositoryLocation(id: id) == nil)
  }

  @Test func localURLIsNilForRemote() {
    #expect(RepositoryLocation.remote(hostProfileID: hostProfileID, path: "/srv").localURL == nil)
  }

  @Test func repositoryLocalInitializerKeepsRootURL() {
    let root = URL(fileURLWithPath: "/tmp/work/app")
    let repository = Repository(id: root.path(percentEncoded: false), rootURL: root, name: "app", worktrees: [])

    #expect(repository.location == .local(root))
    #expect(repository.localURL == root)
    #expect(repository.localURL! == root)
  }

  @Test func remoteRepositoryHasNoLocalURL() {
    let location = RepositoryLocation.remote(hostProfileID: hostProfileID, path: "/home/dev/app")
    let repository = Repository(id: location.id, location: location, name: "app", worktrees: [])

    #expect(repository.localURL == nil)
  }

  @Test func linkedLocalWorktreeKeepsBothPathsAndIsNotMain() {
    let root = URL(fileURLWithPath: "/tmp/work/app")
    let linked = URL(fileURLWithPath: "/tmp/work/app-feature")
    let worktree = Worktree(
      id: linked.path(percentEncoded: false),
      name: "feature",
      detail: "",
      workingDirectory: linked,
      repositoryRootURL: root
    )

    #expect(worktree.location == .local(linked))
    #expect(worktree.repositoryLocation == .local(root))
    #expect(worktree.localURL! == linked)
    #expect(worktree.repositoryLocalURL! == root)
    #expect(worktree.localURL == linked)
    #expect(worktree.repositoryLocalURL == root)
    #expect(!worktree.isMain)
    #expect(worktree.scriptEnvironment["PROWL_WORKTREE_PATH"] == "/tmp/work/app-feature")
    #expect(worktree.scriptEnvironment["PROWL_ROOT_PATH"] == "/tmp/work/app")
  }

  @Test func remotePlainFolderTerminalWorktreeUsesItsLocation() throws {
    let location = RepositoryLocation.remote(hostProfileID: hostProfileID, path: "/home/dev/notes")
    let repository = Repository(id: location.id, location: location, name: "notes", kind: .plain, worktrees: [])

    let worktree = try #require(repository.terminalWorktree)

    #expect(worktree.id == location.id)
    #expect(worktree.location == location)
    #expect(worktree.repositoryLocation == location)
    #expect(worktree.detail == "/home/dev/notes")
    #expect(worktree.isMain)
  }

  @Test func repositoryNameComesFromTheLocationPath() {
    #expect(Repository.name(for: .remote(hostProfileID: hostProfileID, path: "/home/dev/app")) == "app")
    #expect(Repository.name(for: .remote(hostProfileID: hostProfileID, path: "/home/dev/app/.bare")) == "app")
    #expect(Repository.name(for: .local(URL(fileURLWithPath: "/tmp/work/notes"))) == "notes")
  }

  @Test func remoteWorktreeAtRepositoryRootIsMain() {
    let root = RepositoryLocation.remote(hostProfileID: hostProfileID, path: "/home/dev/app")
    let linked = RepositoryLocation.remote(hostProfileID: hostProfileID, path: "/home/dev/app-feature")

    let main = Worktree(id: root.id, name: "main", detail: "", location: root, repositoryLocation: root)
    let feature = Worktree(id: linked.id, name: "feature", detail: "", location: linked, repositoryLocation: root)

    #expect(main.isMain)
    #expect(!feature.isMain)
    #expect(main.localURL == nil)
  }
}

struct RepositoryIDNormalizerTests {
  @Test func normalizesLocalPathsAsBefore() {
    #expect(RepositoryIDNormalizer.normalize(["/tmp/work/./app", "/tmp/work/app"]) == ["/tmp/work/app"])
  }

  @Test func keepsRemoteIDsExactly() {
    let id = "ssh:5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42:/home/dev/my app"

    #expect(RepositoryIDNormalizer.normalize([id]) == [id])
  }

  @Test func neverPrependsTheHomeDirectoryToAnUnknownID() {
    #expect(RepositoryIDNormalizer.normalize(["relative/path"]) == ["relative/path"])
  }

  @Test func dropsBlankIDsAndDuplicates() {
    let id = "ssh:5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42:/srv"

    #expect(RepositoryIDNormalizer.normalize(["  ", id, id]) == [id])
  }

  @Test func worktreeOrderKeepsRemoteKeysAndValues() {
    let repositoryID = "ssh:5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42:/home/dev/app"
    let worktreeID = "ssh:5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42:/home/dev/app-feature"

    let normalized = RepositoryOrderNormalizer.normalizeWorktreeOrderByRepository([repositoryID: [worktreeID]])

    #expect(normalized == [repositoryID: [worktreeID]])
    #expect(RepositoryOrderNormalizer.normalizeRepositoryIDs([repositoryID]) == [repositoryID])
  }

  @Test func rootsKeepRemoteIDsAndResolveRelativePathsAgainstHome() {
    let remote = "ssh:5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42:/home/dev/app"
    let home = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "src/app", directoryHint: .inferFromPath)
      .standardizedFileURL
      .path(percentEncoded: false)

    #expect(RepositoryIDNormalizer.normalizeRoots([remote, "src/app"]) == [remote, home])
  }

  @Test func worktreeOrderKeepsLocalKeyNormalization() {
    let key = "/tmp/prowl-order-key-\(UUID().uuidString)/"
    let expected = URL(fileURLWithPath: key).standardizedFileURL.path(percentEncoded: false)

    let normalized = RepositoryOrderNormalizer.normalizeWorktreeOrderByRepository([key: ["/tmp/wt"]])

    #expect(Array(normalized.keys) == [expected])
    #expect(expected.hasSuffix("/"))
  }

  @Test func repositoryEntriesKeepRemotePaths() {
    let path = "ssh:5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42:/home/dev/app"

    let normalized = RepositoryEntryNormalizer.normalize([PersistedRepositoryEntry(path: path, kind: .git)])

    #expect(normalized == [PersistedRepositoryEntry(path: path, kind: .git)])
  }
}
