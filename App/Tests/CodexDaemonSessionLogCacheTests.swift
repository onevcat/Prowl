import Foundation
import Synchronization
import Testing

@testable import Prowl

struct CodexDaemonSessionLogCacheTests {
  @Test func unchangedLargeLogIsReadOnceAndSelectionChangesInvalidateIt() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "prowl-log-cache-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pane = UUID()
    let url = CodexTUISessionLog.url(for: pane, in: directory)
    let start = #"{"ts":"2026-09-28T14:25:00.000Z","kind":"session_start"}"# + "\n"
    let reset = #"{"ts":"2026-09-28T14:25:01.000Z","kind":"new_session"}"# + "\n"
    let padding = String(repeating: #"{"kind":"irrelevant"}"# + "\n", count: 100_000)
    let original = Data((start + padding).utf8)
    try original.write(to: url)
    let reads = Mutex(0)
    let mapper = CodexDaemonThreadMapper(
      sessionLogDirectory: directory,
      readSessionLog: { url in
        reads.withLock { $0 += 1 }
        return try Data(contentsOf: url)
      }, openFilePaths: { _ in [] })
    let tuiStart = Date(timeIntervalSince1970: 1_790_605_490)
    for _ in 0..<20 {
      let result = await mapper.bindingLookup(surfaceID: pane, daemonPID: 1, tuiStartedAt: tuiStart)
      if case .unavailable = result {} else { Issue.record("No selected thread exists") }
      #expect(await mapper.pane(threadID: "missing", daemonPID: 1) == nil)
    }
    #expect(reads.withLock { $0 } == 1)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(reset.utf8))
    try handle.close()
    let changed = await mapper.bindingLookup(surfaceID: pane, daemonPID: 1, tuiStartedAt: tuiStart)
    if case .selectionPending = changed {
    } else {
      Issue.record("Appended selection must be observed immediately")
    }
    #expect(reads.withLock { $0 } == 2)
    // Same-sized atomic replacement must not reuse the old inode's selection.
    let replacement = Data((start + padding + String(repeating: " ", count: reset.utf8.count)).utf8)
    try replacement.write(to: url, options: .atomic)
    let replaced = await mapper.bindingLookup(surfaceID: pane, daemonPID: 1, tuiStartedAt: tuiStart)
    if case .unavailable = replaced {
    } else {
      Issue.record("Replaced log must invalidate selection")
    }
    #expect(reads.withLock { $0 } == 3)
    try Data(start.utf8).write(to: url)
    _ = await mapper.bindingLookup(surfaceID: pane, daemonPID: 1, tuiStartedAt: tuiStart)
    #expect(reads.withLock { $0 } == 4)
    try FileManager.default.removeItem(at: url)
    let removed = await mapper.bindingLookup(surfaceID: pane, daemonPID: 1, tuiStartedAt: tuiStart)
    if case .unavailable = removed {
    } else {
      Issue.record("Deleted log must not replay cached selection")
    }
  }

  @Test func sameSizeRewriteWithRestoredModificationTimeInvalidatesSelection() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "prowl-log-rewrite-\(UUID())")
    defer { try? FileManager.default.removeItem(at: url) }
    let pane = UUID()
    let start = #"{"ts":"2026-09-28T14:25:00.000Z","kind":"session_start"}"# + "\n"
    let reset = #"{"ts":"2026-09-28T14:25:01.000Z","kind":"new_session"}"# + "\n"
    try Data((start + reset).utf8).write(to: url)
    let modified = try #require(
      FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    var cache = CodexTUISessionLogCache(read: CodexTUISessionLogCache.readStable)
    #expect(cache.record(at: url, surfaceID: pane)?.selectionSubmitOffset == 0)
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(
      contentsOf: Data((start + reset.replacing("new_session", with: "other_event")).utf8))
    try handle.close()
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    let record = cache.record(at: url, surfaceID: pane)
    let rewritten = try #require(record)
    #expect(rewritten.selectionSubmitOffset == nil)
  }

  @Test func changingReadIsNotCachedAndOversizedFilesAreNotRead() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "prowl-log-race-\(UUID())")
    defer { try? FileManager.default.removeItem(at: url) }
    let pane = UUID()
    let start = #"{"ts":"2026-09-28T14:25:00.000Z","kind":"session_start"}"# + "\n"
    try Data(start.utf8).write(to: url)
    let reads = Mutex(0)
    var cache = CodexTUISessionLogCache(read: { url in
      let count = reads.withLock {
        $0 += 1
        return $0
      }
      let data = try Data(contentsOf: url)
      if count == 1 { try Data((start + "\n").utf8).write(to: url, options: .atomic) }
      return data
    })
    #expect(cache.record(at: url, surfaceID: pane) == nil)
    #expect(cache.record(at: url, surfaceID: pane) != nil)
    #expect(reads.withLock { $0 } == 2)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(CodexTUISessionLogCache.maximumBytes + 1))
    try handle.close()
    #expect(cache.record(at: url, surfaceID: pane) == nil)
    #expect(reads.withLock { $0 } == 2)
  }

}
