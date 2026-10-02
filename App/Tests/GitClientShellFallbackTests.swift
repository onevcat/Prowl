import Foundation
import Testing

@testable import supacode

struct GitClientShellFallbackTests {
  private func error(_ stderr: String, exitCode: Int32 = 128) -> ShellClientError {
    ShellClientError(
      command: "git rev-parse --git-dir", stdout: "", stderr: stderr, exitCode: exitCode)
  }

  @Test func directNonRepositoryRequiresAbsentMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let failure = error("fatal: not a git repository (or any of the parent directories): .git\n")
    #expect(isConfirmedNonRepository(failure, at: root))
    try Data("gitdir: /missing".utf8).write(to: root.appending(path: ".git"))
    #expect(!isConfirmedNonRepository(failure, at: root))
  }

  @Test func filesystemBoundaryRequiresAbsentMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let message = """
      fatal: not a git repository (or any parent up to mount point /Volumes)
      Stopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).
      """
    #expect(isConfirmedNonRepository(error(message), at: root))
    #expect(!isConfirmedNonRepository(error(message, exitCode: 1), at: root))
    #expect(!isConfirmedNonRepository(error("xcrun failed\n" + message), at: root))
    #expect(!isConfirmedNonRepository(error(message + "\nPermission denied"), at: root))
    try Data("gitdir: /missing".utf8).write(to: root.appending(path: ".git"))
    #expect(!isConfirmedNonRepository(error(message), at: root))
  }

  @Test func symlinkedFolderDoesNotHideAncestorMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString, directoryHint: .isDirectory)
    let real = root.appending(path: "real", directoryHint: .isDirectory)
    let child = real.appending(path: "child", directoryHint: .isDirectory)
    let alias = root.appending(path: "alias", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("gitdir: /missing".utf8).write(to: real.appending(path: ".git"))
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
    let failure = error("fatal: not a git repository (or any of the parent directories): .git")
    #expect(!isConfirmedNonRepository(failure, at: alias))
  }

  @Test func toolchainConfigurationAndAccessFailuresAreNotPlainFolders() {
    let root = URL(fileURLWithPath: "/tmp")
    for stderr in [
      "xcrun: error: missing DEVELOPER_DIR path: /missing\nerror: not a git repository",
      "fatal: bad config line 1\nerror: not a git repository",
      "fatal: detected dubious ownership in repository",
      "fatal: cannot chdir: Permission denied",
    ] {
      #expect(!isConfirmedNonRepository(error(stderr), at: root))
    }
    #expect(!isConfirmedNonRepository(error("not a git repository", exitCode: 1), at: root))
  }
}
