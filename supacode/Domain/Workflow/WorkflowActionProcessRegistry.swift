import Darwin
import Foundation
import ProwlCLIShared

/// App-owned ownership records survive a crash. Repository files never authorize process termination.
nonisolated struct WorkflowActionProcessRegistry: Sendable {
  struct Identity: Codable, Equatable, Sendable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64

    static func capture(_ pid: Int32) -> Self? {
      guard let info = ProcessDetection.processBSDInfo(pid: pid) else { return nil }
      return Self(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    var isCurrent: Bool { Self.capture(pid) == self }
  }

  struct Record: Codable, Sendable {
    let owner: Identity
    let process: Identity
  }

  let directory: URL
  private let storage: WorkflowHistoryStorage
  var processGroup: @Sendable (Int32) -> Int32 = { getpgid($0) }
  var terminateGroup: @Sendable (Int32) -> Bool = { kill(-$0, SIGKILL) == 0 }

  init(
    directory: URL = WorkflowHistoryStorage.configured.baseURL.appending(path: ".processes")
  ) {
    storage = WorkflowHistoryStorage(baseURL: directory.deletingLastPathComponent())
    self.directory = storage.baseURL.appending(path: directory.lastPathComponent)
  }

  func register(executionID: String, pid: Int32) throws {
    guard UUID(uuidString: executionID) != nil, let owner = Identity.capture(getpid()),
      let process = Identity.capture(pid), processGroup(pid) == pid
    else {
      throw WorkflowActionError.failed("Cannot record action process ownership.")
    }
    try storage.prepare(directory)
    let file = directory.appending(path: executionID + ".json")
    try storage.validate(file, allowMissing: true)
    try JSONEncoder().encode(Record(owner: owner, process: process)).write(to: file, options: .atomic)
  }

  func remove(executionID: String) {
    guard UUID(uuidString: executionID) != nil else { return }
    let file = directory.appending(path: executionID + ".json")
    guard (try? storage.validate(file)) != nil else { return }
    try? FileManager.default.removeItem(at: file)
  }

  @discardableResult func recoverAbandonedProcesses() throws -> Int {
    try storage.validate(directory, allowMissing: true)
    guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
    let files = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    var terminated = 0
    for file in files where file.pathExtension == "json" {
      guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
        let record = try? JSONDecoder().decode(Record.self, from: storage.read(file))
      else { continue }
      guard !record.owner.isCurrent else { continue }
      if record.process.isCurrent, processGroup(record.process.pid) == record.process.pid {
        if terminateGroup(record.process.pid) { terminated += 1 }
      }
      try storage.validate(file)
      try FileManager.default.removeItem(at: file)
    }
    return terminated
  }
}
