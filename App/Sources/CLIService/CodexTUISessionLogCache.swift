import Darwin
import Foundation

/// Shared by caller routing and selected-session lookup. Cache parsed records, never prompt bytes.
nonisolated struct CodexTUISessionLogCache {
  static let maximumBytes = 64 * 1_024 * 1_024

  private struct Snapshot: Equatable {
    let value: stat

    init?(_ url: URL) {
      var value = stat()
      guard lstat(url.path(percentEncoded: false), &value) == 0,
        (value.st_mode & S_IFMT) == S_IFREG, value.st_uid == geteuid(),
        value.st_size >= 0, value.st_size <= CodexTUISessionLogCache.maximumBytes
      else { return nil }
      self.value = value
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.value.st_dev == rhs.value.st_dev && lhs.value.st_ino == rhs.value.st_ino
        && lhs.value.st_size == rhs.value.st_size
        && lhs.value.st_mtimespec.tv_sec == rhs.value.st_mtimespec.tv_sec
        && lhs.value.st_mtimespec.tv_nsec == rhs.value.st_mtimespec.tv_nsec
        && lhs.value.st_ctimespec.tv_sec == rhs.value.st_ctimespec.tv_sec
        && lhs.value.st_ctimespec.tv_nsec == rhs.value.st_ctimespec.tv_nsec
    }
  }

  private struct Entry {
    let snapshot: Snapshot
    let record: CodexTUISessionRecord?
  }

  private var entries: [UUID: Entry] = [:]
  private let read: @Sendable (URL) throws -> Data

  init(read: @escaping @Sendable (URL) throws -> Data) {
    self.read = read
  }

  static func readStable(_ url: URL) throws -> Data {
    guard case .stable(let data) = StableOwnerFileReader.read(url, maximumBytes: maximumBytes)
    else {
      throw CocoaError(.fileReadUnknown)
    }
    return data
  }

  mutating func record(at url: URL, surfaceID: UUID) -> CodexTUISessionRecord? {
    guard let before = Snapshot(url) else {
      entries[surfaceID] = nil
      return nil
    }
    if let cached = entries[surfaceID], cached.snapshot == before { return cached.record }
    entries[surfaceID] = nil
    guard let data = try? read(url), data.count == before.value.st_size,
      let after = Snapshot(url), before == after
    else { return nil }
    let record = CodexDaemonThreadMapper.parseSessionLog(data, surfaceID: surfaceID)
    // Bound both pane count and the source bytes represented by retained records.
    let retainedBytes = entries.values.reduce(Int64(0)) { $0 + $1.snapshot.value.st_size }
    if entries.count >= 128 || retainedBytes + before.value.st_size > Self.maximumBytes {
      entries.removeAll(keepingCapacity: true)
    }
    entries[surfaceID] = Entry(snapshot: before, record: record)
    return record
  }
}
