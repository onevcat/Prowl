import Clocks
import Darwin
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct CodexForwardingRecordStoreTests {
  @Test func recordUsesRandomOwnerOnlyDirectoryAndExactArgv() throws {
    let base = temporaryDirectory("forward-record")
    defer { try? FileManager.default.removeItem(at: base) }
    let store = try CodexForwardingRecordStore(baseDirectory: base, retirementGrace: 2)
    let argv = ["/tmp/notifier with space", "", "quote=\"x\"", "秘密-like"]

    let first = try store.create(argv: argv)
    let second = try store.create(argv: argv)
    #expect(first.locator != second.locator)
    #expect(mode(of: first.locator.deletingLastPathComponent()) == 0o700)
    #expect(mode(of: first.locator) == 0o600)

    let lease = try CodexForwardingRecordReader.open(first.locator)
    #expect(lease.argv == argv)
    lease.close()
  }

  @Test func retirementWaitsForGraceAndActiveSharedLease() throws {
    let base = temporaryDirectory("forward-retire")
    defer { try? FileManager.default.removeItem(at: base) }
    var now = Date(timeIntervalSince1970: 100)
    let store = try CodexForwardingRecordStore(
      baseDirectory: base,
      retirementGrace: 2,
      now: { now }
    )
    let record = try store.create(argv: ["/tmp/notifier"])
    let lease = try CodexForwardingRecordReader.open(record.locator)

    store.retire(record)
    store.cleanupRetired()
    #expect(FileManager.default.fileExists(atPath: record.locator.path(percentEncoded: false)))

    now.addTimeInterval(3)
    store.cleanupRetired()
    #expect(FileManager.default.fileExists(atPath: record.locator.path(percentEncoded: false)))

    lease.close()
    store.cleanupRetired()
    #expect(!FileManager.default.fileExists(atPath: record.locator.path(percentEncoded: false)))
  }

  @Test func scheduledCleanupRetriesAfterTheFirstLeaseConflict() async throws {
    let base = temporaryDirectory("forward-scheduled-retire")
    defer { try? FileManager.default.removeItem(at: base) }
    var now = Date(timeIntervalSince1970: 100)
    let clock = TestClock()
    let store = try CodexForwardingRecordStore(
      baseDirectory: base,
      retirementGrace: 1,
      now: { now },
      retirementClock: clock
    )
    let record = try store.create(argv: ["/tmp/notifier"])
    let lease = try CodexForwardingRecordReader.open(record.locator)
    store.retire(record)
    await Task.yield()

    now.addTimeInterval(2)
    await clock.advance(by: .seconds(1))
    #expect(FileManager.default.fileExists(atPath: record.locator.path(percentEncoded: false)))

    lease.close()
    now.addTimeInterval(2)
    await clock.advance(by: .seconds(1))
    #expect(!FileManager.default.fileExists(atPath: record.locator.path(percentEncoded: false)))
  }

  @Test func readerRejectsSymlinkPermissionDriftAndOversizedRecords() throws {
    let base = temporaryDirectory("forward-invalid")
    defer { try? FileManager.default.removeItem(at: base) }
    let store = try CodexForwardingRecordStore(baseDirectory: base, retirementGrace: 0)
    let record = try store.create(argv: ["/tmp/notifier"])

    chmod(record.locator.path(percentEncoded: false), 0o644)
    #expect(throws: CodexForwardingRecordError.invalidRecord) {
      try CodexForwardingRecordReader.open(record.locator)
    }

    let target = base.appending(path: "target", directoryHint: .notDirectory)
    try Data(#"["/tmp/notifier"]"#.utf8).write(to: target)
    let link = base.appending(path: "link", directoryHint: .notDirectory)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: CodexForwardingRecordError.invalidRecord) {
      try CodexForwardingRecordReader.open(link)
    }
  }

  @Test func orphanSweepKeepsAgedLiveStoreAndRemovesItAfterOwnerExit() throws {
    let base = temporaryDirectory("forward-orphans")
    defer { try? FileManager.default.removeItem(at: base) }
    var now = Date(timeIntervalSince1970: 1_000)
    var oldStore: CodexForwardingRecordStore? = try CodexForwardingRecordStore(
      baseDirectory: base,
      retirementGrace: 0,
      orphanMaximumAge: 60,
      now: { now }
    )
    let oldRecord = try #require(oldStore).create(argv: ["/tmp/old"])
    now.addTimeInterval(120)

    let liveStore = try CodexForwardingRecordStore(
      baseDirectory: base,
      retirementGrace: 0,
      orphanMaximumAge: 60,
      now: { now }
    )
    let liveRecord = try liveStore.create(argv: ["/tmp/live"])
    liveStore.sweepOrphans()

    #expect(FileManager.default.fileExists(atPath: oldRecord.locator.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: liveRecord.locator.path(percentEncoded: false)))

    oldStore = nil
    liveStore.sweepOrphans()
    #expect(!FileManager.default.fileExists(atPath: oldRecord.locator.path(percentEncoded: false)))
  }

  private func temporaryDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "prowl-tests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func mode(of url: URL) -> mode_t? {
    var value = stat()
    guard lstat(url.path(percentEncoded: false), &value) == 0 else { return nil }
    return value.st_mode & 0o777
  }
}
