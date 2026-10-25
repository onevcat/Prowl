import Foundation
import IdentifiedCollections
import Testing

@testable import Prowl

struct RepositoryNameTests {
  @Test func usesParentDirectoryNameForBareRepositoryRoots() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha/.bare")

    #expect(Repository.name(for: root) == "repo-alpha")
  }

  @Test func preservesNormalRepositoryName() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")

    #expect(Repository.name(for: root) == "repo-alpha")
  }
}

struct RepositoryTerminalWorktreeTests {
  @Test func plainFolderIsItsOwnTerminalWorktree() throws {
    let root = URL(fileURLWithPath: "/tmp/work/notes")
    let repository = Repository(
      id: root.path(percentEncoded: false), rootURL: root, name: "notes", kind: .plain, worktrees: [])

    let worktree = try #require(repository.terminalWorktree)

    #expect(worktree.id == repository.id)
    #expect(worktree.name == "notes")
    #expect(worktree.detail == "/tmp/work/notes")
    #expect(worktree.localURL! == root)
    #expect(worktree.repositoryLocalURL! == root)
    #expect(worktree.isMain)
  }

  @Test func workspaceUsesItsRootAsTerminalWorktree() throws {
    let root = URL(fileURLWithPath: "/tmp/work/feature-space")
    let repository = Repository(
      id: root.path(percentEncoded: false),
      rootURL: root,
      name: "Feature",
      kind: .git,
      worktrees: [],
      workspace: ProjectWorkspace(title: "Feature")
    )

    let worktree = try #require(repository.terminalWorktree)

    #expect(worktree.id == repository.id)
    #expect(worktree.name == "Feature")
    #expect(worktree.localURL! == root)
  }

  @Test func gitRepositoryHasNoTerminalWorktree() {
    let root = URL(fileURLWithPath: "/tmp/work/app")
    let main = Worktree(
      id: root.path(percentEncoded: false), name: "main", detail: "", workingDirectory: root, repositoryRootURL: root)
    let repository = Repository(
      id: root.path(percentEncoded: false), rootURL: root, name: "app", kind: .git, worktrees: [main])

    #expect(repository.terminalWorktree == nil)
  }
}

struct ProwlPathsTests {
  @Test func repositoryDirectoryUsesRepoNameForNormalRoots() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")
    let directory = ProwlPaths.repositoryDirectory(for: root)

    #expect(directory.lastPathComponent == "repo-alpha")
  }

  @Test func repositoryDirectoryUsesSanitizedPathForBareRoots() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha/.bare")
    let directory = ProwlPaths.repositoryDirectory(for: root)

    #expect(directory.lastPathComponent == "tmp_work_repo-alpha_.bare")
  }

  @Test func repositoryDirectoryDoesNotCollideForDifferentBareRoots() {
    let firstRoot = URL(fileURLWithPath: "/tmp/work/repo-alpha/.bare")
    let secondRoot = URL(fileURLWithPath: "/tmp/work/repo-beta/.bare")

    let firstDirectory = ProwlPaths.repositoryDirectory(for: firstRoot)
    let secondDirectory = ProwlPaths.repositoryDirectory(for: secondRoot)

    #expect(firstDirectory != secondDirectory)
  }

  @Test func repositorySettingsURLUsesProwlRepoDirectory() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")
    let settingsURL = ProwlPaths.repositorySettingsURL(for: root)

    #expect(settingsURL.lastPathComponent == "prowl.json")
    #expect(settingsURL.deletingLastPathComponent().lastPathComponent == "repo-alpha-74ffb938")
    #expect(settingsURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "repo")
  }

  @Test func userRepositorySettingsURLUsesProwlRepoDirectory() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha/.bare")
    let settingsURL = ProwlPaths.userRepositorySettingsURL(for: root)

    #expect(settingsURL.lastPathComponent == "prowl.user.json")
    #expect(settingsURL.deletingLastPathComponent().lastPathComponent.hasPrefix(".bare-"))
    #expect(settingsURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "repo")
  }

  @Test func repositorySettingsDirectoriesKeepOneBasenameApart() {
    let first = ProwlPaths.repositorySettingsURL(for: URL(fileURLWithPath: "/tmp/work/repo-alpha"))
    let second = ProwlPaths.repositorySettingsURL(for: URL(fileURLWithPath: "/tmp/other/repo-alpha"))

    #expect(second.deletingLastPathComponent().lastPathComponent == "repo-alpha-085a6d8f")
    #expect(first != second)
  }

  @Test func repositorySettingsDirectoryIgnoresTrailingSlash() {
    let plain = ProwlPaths.repositorySettingsURL(for: URL(fileURLWithPath: "/tmp/work/repo-alpha"))
    let slashed = ProwlPaths.repositorySettingsURL(
      for: URL(fileURLWithPath: "/tmp/work/repo-alpha/", isDirectory: true))

    #expect(plain == slashed)
  }

  @Test func repositorySettingsDirectoryForRemoteLocationUsesItsID() throws {
    let hostProfileID = try #require(UUID(uuidString: "5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42"))
    let directory = ProwlPaths.repositorySettingsDirectory(
      for: .remote(hostProfileID: hostProfileID, path: "/home/dev/app")
    )

    #expect(directory.lastPathComponent == "app-22ee2f59")
  }

  @Test func rootRepositorySettingsDirectoryUsesPlaceholderName() {
    let directory = ProwlPaths.repositorySettingsDirectory(for: .local(URL(fileURLWithPath: "/")))

    #expect(directory.lastPathComponent == "_-8a5edab2")
  }

  @Test func legacySettingsLiveInTheBasenameDirectory() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")

    #expect(
      ProwlPaths.legacyRepositorySettingsURLs(for: root).map(\.lastPathComponent) == ["prowl.json", "supacode.json"])
    #expect(
      ProwlPaths.legacyUserRepositorySettingsURLs(for: root).map(\.lastPathComponent)
        == ["prowl.user.json", "prowl.onevcat.json", "supacode.onevcat.json"]
    )
    for url in ProwlPaths.legacyRepositorySettingsURLs(for: root)
      + ProwlPaths.legacyUserRepositorySettingsURLs(for: root)
    {
      #expect(url.deletingLastPathComponent().lastPathComponent == "repo-alpha")
    }
  }

  @Test func iconFileURLFallsBackToTheBasenameDirectory() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "prowl-icons-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let current = base.appending(path: "current", directoryHint: .isDirectory)
    let legacy = base.appending(path: "legacy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try Data("icon".utf8).write(to: legacy.appending(path: "a.png"))

    #expect(ProwlPaths.iconFileURL(filename: "a.png", in: current, fallback: legacy) == legacy.appending(path: "a.png"))
    #expect(
      ProwlPaths.iconFileURL(filename: "b.png", in: current, fallback: legacy) == current.appending(path: "b.png"))
    #expect(ProwlPaths.iconFileURL(filename: "a.png", in: current, fallback: nil) == current.appending(path: "a.png"))
  }

  @Test func longBasenameStaysUnderTheFileNameLimit() {
    let longName = String(repeating: "界", count: 120)
    let directory = ProwlPaths.repositorySettingsDirectory(for: .local(URL(fileURLWithPath: "/tmp/\(longName)")))

    #expect(directory.lastPathComponent.utf8.count <= 255)
    #expect(directory.lastPathComponent.hasPrefix("界"))
  }

  @Test func worktreeBaseDirectoryDefaultsToLegacyRepositoryDirectory() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")
    let directory = ProwlPaths.worktreeBaseDirectory(
      for: root,
      globalDefaultPath: nil,
      repositoryOverridePath: nil
    )

    #expect(directory == ProwlPaths.repositoryDirectory(for: root))
  }

  @Test func worktreeBaseDirectoryUsesGlobalParentDirectory() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")
    let directory = ProwlPaths.worktreeBaseDirectory(
      for: root,
      globalDefaultPath: "/tmp/worktrees",
      repositoryOverridePath: nil
    )
    let expectedDirectory = URL(filePath: "/tmp/worktrees/repo-alpha", directoryHint: .isDirectory)
      .standardizedFileURL

    #expect(directory == expectedDirectory)
  }

  @Test func worktreeBaseDirectoryRepositoryOverrideTakesPrecedence() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")
    let directory = ProwlPaths.worktreeBaseDirectory(
      for: root,
      globalDefaultPath: "/tmp/worktrees",
      repositoryOverridePath: "/tmp/repo-alpha-worktrees"
    )
    let expectedDirectory = URL(filePath: "/tmp/repo-alpha-worktrees", directoryHint: .isDirectory)
      .standardizedFileURL

    #expect(directory == expectedDirectory)
  }

  @Test func exampleWorktreePathUsesResolvedBaseDirectory() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")
    let path = ProwlPaths.exampleWorktreePath(
      for: root,
      globalDefaultPath: "/tmp/worktrees",
      repositoryOverridePath: nil
    )
    let expectedPath = URL(filePath: "/tmp/worktrees/repo-alpha/swift-otter", directoryHint: .isDirectory)
      .standardizedFileURL
      .path(percentEncoded: false)

    #expect(path == expectedPath)
  }

  @Test func repositorySnapshotURLUsesAppSupportCacheDirectory() {
    let path = ProwlPaths.repositorySnapshotURL.path(percentEncoded: false)

    #expect(path.contains("/Library/Application Support/com.onevcat.prowl/cache/"))
  }

  @Test func migrateLegacyCacheMovesSnapshotFilesToCacheDirectory() throws {
    let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let legacyDirectory = tempRoot.appending(path: "legacy", directoryHint: .isDirectory)
    let cacheDirectory = tempRoot.appending(path: "cache", directoryHint: .isDirectory)
    let repositorySnapshot = legacyDirectory.appending(path: "repository-snapshot.json", directoryHint: .notDirectory)
    let terminalSnapshot = legacyDirectory.appending(
      path: "terminal-layout-snapshot.json",
      directoryHint: .notDirectory
    )

    try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
    try Data("repo".utf8).write(to: repositorySnapshot)
    try Data("terminal".utf8).write(to: terminalSnapshot)

    try ProwlPaths.migrateLegacyCacheFilesIfNeeded(
      legacyDirectory: legacyDirectory,
      cacheDirectory: cacheDirectory
    )

    let migratedRepositorySnapshotPath =
      cacheDirectory
      .appending(path: "repository-snapshot.json")
      .path(percentEncoded: false)
    let migratedTerminalSnapshotPath =
      cacheDirectory
      .appending(path: "terminal-layout-snapshot.json")
      .path(percentEncoded: false)
    #expect(FileManager.default.fileExists(atPath: migratedRepositorySnapshotPath))
    #expect(FileManager.default.fileExists(atPath: migratedTerminalSnapshotPath))
    #expect(!FileManager.default.fileExists(atPath: repositorySnapshot.path(percentEncoded: false)))
    #expect(!FileManager.default.fileExists(atPath: terminalSnapshot.path(percentEncoded: false)))

    try? FileManager.default.removeItem(at: tempRoot)
  }
}
