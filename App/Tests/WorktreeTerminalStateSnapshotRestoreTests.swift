import Foundation
import Testing

@testable import supacode

struct SnapshotRestoreTests {
  @Test func resolveSnapshotWorkingDirectoryAcceptsAbsolutePathWithinWorktree() throws {
    let fileManager = FileManager.default
    let worktreeRoot = try makeTemporaryDirectory(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: worktreeRoot) }

    let nested = worktreeRoot.appending(path: "src", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)

    let resolved = WorktreeTerminalState.resolveSnapshotWorkingDirectory(
      from: nested.path(percentEncoded: false),
      worktreeRoot: worktreeRoot,
      fileManager: fileManager
    )

    #expect(resolved == nested.standardizedFileURL)
  }

  @Test func resolveSnapshotWorkingDirectoryAcceptsRelativePathWithinWorktree() throws {
    let fileManager = FileManager.default
    let worktreeRoot = try makeTemporaryDirectory(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: worktreeRoot) }

    let nested = worktreeRoot.appending(path: "relative/path", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)

    let resolved = WorktreeTerminalState.resolveSnapshotWorkingDirectory(
      from: "relative/path",
      worktreeRoot: worktreeRoot,
      fileManager: fileManager
    )

    #expect(resolved == nested.standardizedFileURL)
  }

  @Test func resolveSnapshotWorkingDirectoryRejectsMissingOrOutsidePath() throws {
    let fileManager = FileManager.default
    let worktreeRoot = try makeTemporaryDirectory(fileManager: fileManager)
    let outsideRoot = try makeTemporaryDirectory(fileManager: fileManager)
    defer {
      try? fileManager.removeItem(at: worktreeRoot)
      try? fileManager.removeItem(at: outsideRoot)
    }

    let outsidePath = outsideRoot.appending(path: "outside", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: outsidePath, withIntermediateDirectories: true)

    let missing = WorktreeTerminalState.resolveSnapshotWorkingDirectory(
      from: worktreeRoot.appending(path: "does-not-exist", directoryHint: .isDirectory)
        .path(percentEncoded: false),
      worktreeRoot: worktreeRoot,
      fileManager: fileManager
    )
    let outside = WorktreeTerminalState.resolveSnapshotWorkingDirectory(
      from: outsidePath.path(percentEncoded: false),
      worktreeRoot: worktreeRoot,
      fileManager: fileManager
    )

    #expect(missing == nil)
    #expect(outside == nil)
  }
}

private func makeTemporaryDirectory(fileManager: FileManager) throws -> URL {
  let url = fileManager.temporaryDirectory.appending(
    path: "worktree-terminal-state-tests-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
