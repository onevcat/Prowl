import Darwin
import Foundation

/// Small history fields are independent of action/state payloads in run.json.
nonisolated public struct WorkflowHistoryMetadata: Codable, Sendable {
  public static let fileName = "history.json"
  public let version: Int
  public let id: UUID
  public let name: String
  public let root: String
  public let state: String
  public let startedAt: Date
  public let finishedAt: Date?
  private var record: RecordIdentity?

  public init(id: UUID, name: String, root: String, state: String, startedAt: Date, finishedAt: Date?) {
    version = 1
    self.id = id
    self.name = String(name.prefix(1024))
    self.root = root
    self.state = state
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }

  var terminal: Bool {
    ["completed", "cancelled", "skipped", "iteration_limit_reached", "interrupted"].contains(state)
  }

  /// Caller holds run occupancy. Missing metadata after a failed write prevents automatic deletion.
  public func write(record data: Data, directory: URL, storage: WorkflowHistoryStorage) throws {
    let recordURL = directory.appending(path: "run.json")
    let metadataURL = directory.appending(path: Self.fileName)
    try storage.validate(recordURL, allowMissing: true)
    try storage.validate(metadataURL, allowMissing: true)
    guard try JSONEncoder().encode(self).count < WorkflowSizeLimits.historyMetadata - 1024 else {
      throw WorkflowHistoryError.invalidRecord
    }
    if FileManager.default.fileExists(atPath: metadataURL.path) {
      try FileManager.default.removeItem(at: metadataURL)
    }
    try data.write(to: recordURL, options: .atomic)
    var metadata = self
    metadata.record = try RecordIdentity(recordURL, storage: storage)
    let encoded = try JSONEncoder().encode(metadata)
    guard encoded.count <= WorkflowSizeLimits.historyMetadata else { throw WorkflowHistoryError.invalidRecord }
    try encoded.write(to: metadataURL, options: .atomic)
  }

  static func read(directory: URL, storage: WorkflowHistoryStorage) throws -> Self {
    let data = try storage.read(directory.appending(path: fileName), limit: WorkflowSizeLimits.historyMetadata)
    let metadata = try JSONDecoder().decode(Self.self, from: data)
    guard metadata.version == 1, metadata.id == UUID(uuidString: directory.lastPathComponent),
      metadata.record == (try RecordIdentity(directory.appending(path: "run.json"), storage: storage))
    else { throw WorkflowHistoryError.invalidRecord }
    return metadata
  }

  /// Detects replacement or modification without loading the full record during history scans.
  private struct RecordIdentity: Codable, Equatable, Sendable {
    let inode: UInt64
    let bytes: Int64
    let seconds: Int64
    let nanoseconds: Int64

    init(_ url: URL, storage: WorkflowHistoryStorage) throws {
      try storage.validate(url)
      var info = stat()
      guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
        throw WorkflowHistoryError.unsafePath(url.path)
      }
      inode = UInt64(info.st_ino)
      bytes = Int64(info.st_size)
      seconds = Int64(info.st_mtimespec.tv_sec)
      nanoseconds = Int64(info.st_mtimespec.tv_nsec)
    }
  }
}
