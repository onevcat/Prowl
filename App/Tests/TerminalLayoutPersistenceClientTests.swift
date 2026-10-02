import Foundation
import Testing

@testable import supacode

struct TerminalLayoutPersistenceClientTests {
  @Test func saveAndLoadSnapshotRoundTrips() throws {
    let fileManager = FileManager.default
    let cacheDirectory = try makeTemporaryDirectory(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: cacheDirectory) }
    let snapshotURL = cacheDirectory.appending(path: "terminal-layout-snapshot.json", directoryHint: .notDirectory)
    let payload = makePayload()

    let saved = saveTerminalLayoutSnapshot(
      payload,
      at: snapshotURL,
      cacheDirectory: cacheDirectory,
      fileManager: fileManager
    )
    #expect(saved)

    let loaded = loadTerminalLayoutSnapshot(at: snapshotURL, fileManager: fileManager)
    #expect(loaded == payload)
  }

  @Test func loadSnapshotDeletesInvalidPayload() throws {
    let fileManager = FileManager.default
    let cacheDirectory = try makeTemporaryDirectory(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: cacheDirectory) }
    let snapshotURL = cacheDirectory.appending(path: "terminal-layout-snapshot.json", directoryHint: .notDirectory)
    try Data("{\"version\":1}".utf8).write(to: snapshotURL, options: .atomic)

    let loaded = loadTerminalLayoutSnapshot(at: snapshotURL, fileManager: fileManager)

    #expect(loaded == nil)
    #expect(fileManager.fileExists(atPath: snapshotURL.path(percentEncoded: false)) == false)
  }

  @Test func loadSnapshotDeletesOversizedPayload() throws {
    let fileManager = FileManager.default
    let cacheDirectory = try makeTemporaryDirectory(fileManager: fileManager)
    defer { try? fileManager.removeItem(at: cacheDirectory) }
    let snapshotURL = cacheDirectory.appending(path: "terminal-layout-snapshot.json", directoryHint: .notDirectory)
    let oversized = Data(repeating: 0, count: TerminalLayoutSnapshotPayload.maxSnapshotFileBytes + 1)
    try oversized.write(to: snapshotURL, options: .atomic)

    let loaded = loadTerminalLayoutSnapshot(at: snapshotURL, fileManager: fileManager)

    #expect(loaded == nil)
    #expect(fileManager.fileExists(atPath: snapshotURL.path(percentEncoded: false)) == false)
  }
}

private func makeTemporaryDirectory(fileManager: FileManager) throws -> URL {
  let url = fileManager.temporaryDirectory.appending(
    path: "terminal-layout-tests-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func makePayload() -> TerminalLayoutSnapshotPayload {
  TerminalLayoutSnapshotPayload(
    worktrees: [
      TerminalLayoutSnapshotPayload.SnapshotWorktree(
        worktreeID: "/tmp/repo/wt-1",
        selectedTabID: "F96839F5-1371-4841-9E41-49124D918A67",
        tabs: [
          TerminalLayoutSnapshotPayload.SnapshotTab(
            tabID: "F96839F5-1371-4841-9E41-49124D918A67",
            title: nil,
            icon: nil,
            splitRoot: .leaf(surfaceID: "9B2F6D8C-44A4-42C5-8F9E-962108301901")
          )
        ]
      )
    ]
  )
}
