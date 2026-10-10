import Foundation
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
    #expect(settingsURL.deletingLastPathComponent().lastPathComponent == "repo-alpha")
    #expect(settingsURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "repo")
  }

  @Test func userRepositorySettingsURLUsesProwlRepoDirectory() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha/.bare")
    let settingsURL = ProwlPaths.userRepositorySettingsURL(for: root)

    #expect(settingsURL.lastPathComponent == "prowl.user.json")
    #expect(settingsURL.deletingLastPathComponent().lastPathComponent == ".bare")
    #expect(settingsURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "repo")
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
