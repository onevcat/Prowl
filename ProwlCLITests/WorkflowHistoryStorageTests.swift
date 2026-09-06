import Foundation
import Testing
@testable import ProwlCLIShared

struct WorkflowHistoryStorageTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func canonicalRootsAndCreationMonthDefineLocation() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appending(path: "a/project")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let alias = base.appending(path: "alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    let storage = WorkflowHistoryStorage(baseURL: base.appending(path: "history"))
    #expect(storage.rootKey(root) == storage.rootKey(alias))
    #expect(storage.rootKey(root) != storage.rootKey(base.appending(path: "b/project")))
    let id = UUID()
    let location = storage.directory(root: root, createdAt: now, runID: id)
    #expect(location.lastPathComponent == id.uuidString)
    #expect(location.deletingLastPathComponent().lastPathComponent == "2027-01")
    try storage.prepare(location)
    try FileManager.default.removeItem(at: root)
    let found = try storage.find(id)
    #expect(found?.path == location.path)
    #expect(!FileManager.default.fileExists(atPath: base.appending(path: "a/.prowl").path))
  }

  @Test func occupancyRejectsAnotherOwnerAndReleasesOnClose() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let storage = WorkflowHistoryStorage(baseURL: base)
    let location = storage.directory(root: URL(filePath: "/project"), createdAt: now, runID: UUID())
    try storage.prepare(location)
    let owner = try storage.occupy(location)
    #expect(throws: (any Error).self) { try storage.occupy(location) }
    owner.close()
    let next = try storage.occupy(location)
    next.close()
  }

  @Test func contentChunksPreserveLargeBinaryArtifactsAndRejectInvalidOffsets() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let storage = WorkflowHistoryStorage(baseURL: base)
    try storage.prepare(storage.baseURL)
    let file = storage.baseURL.appending(path: "artifact.bin")
    let bytes = Data((0..<150_000).map { UInt8($0 % 256) })
    try bytes.write(to: file)
    let first = try storage.readChunk(file, offset: 0)
    let second = try storage.readChunk(file, offset: first.nextOffset!)
    let third = try storage.readChunk(file, offset: second.nextOffset!)
    #expect(first.data + second.data + third.data == bytes)
    #expect(third.nextOffset == nil)
    #expect(throws: (any Error).self) { try storage.readChunk(file, offset: -1) }
    #expect(throws: (any Error).self) { try storage.readChunk(file, offset: 150_001) }
  }

  @Test func occupancyCoordinatesAcrossProcesses() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let storage = WorkflowHistoryStorage(baseURL: base)
    let directory = storage.directory(root: base, createdAt: now, runID: UUID())
    try storage.prepare(directory)
    let owner = try storage.occupy(directory)
    defer { owner.close() }
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/python3")
    process.arguments = ["-c", """
      import fcntl, sys
      with open(sys.argv[1], 'r+') as stream:
          try:
              fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
          except BlockingIOError:
              sys.exit(0)
          sys.exit(1)
      """, directory.appending(path: ".occupancy.lock").path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }

  @Test func containmentRejectsLinksAndSpecialFiles() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let storage = WorkflowHistoryStorage(baseURL: base.appending(path: "history"))
    let location = storage.directory(root: base, createdAt: now, runID: UUID())
    try storage.prepare(location)
    let outside = base.appending(path: "outside")
    try Data("keep".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: location.appending(path: "link"), withDestinationURL: outside)
    #expect(throws: (any Error).self) { try storage.files(in: location) }
    #expect(throws: (any Error).self) { try storage.prepare(base.appending(path: "elsewhere")) }
    #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
  }
}
