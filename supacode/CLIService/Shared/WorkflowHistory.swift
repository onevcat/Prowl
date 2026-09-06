import CryptoKit
import Foundation

nonisolated public struct WorkflowHistoryEntry: Equatable, Identifiable, Sendable {
  public let id: UUID
  public let directory: URL
  public let name: String
  public let root: String
  public let state: String
  public let finishedAt: Date?
  public let bytes: Int64
  public let pinned: Bool
  public let protection: String?
}

nonisolated public struct WorkflowHistoryPreview: Equatable, Sendable {
  public static let budget: Int64 = 5 * 1024 * 1024 * 1024
  public static let retention: TimeInterval = 30 * 86400
  public static let grace: TimeInterval = 86400
  public let issues: [String]
  public let entries: [WorkflowHistoryEntry]
  public let candidates: [WorkflowHistoryEntry]
  public let protectedEntries: [WorkflowHistoryEntry]
  public let totalBytes: Int64
  public let reclaimedBytes: Int64
  public let remainingBytes: Int64
  public let overBudget: Bool

  public init(entries: [WorkflowHistoryEntry], now: Date, budget: Int64 = Self.budget, issues: [String] = []) {
    self.issues = issues
    self.entries = entries
    totalBytes = entries.reduce(0) { $0 + $1.bytes }
    let eligible = entries.filter {
      $0.protection == nil && !$0.pinned && $0.finishedAt.map { now.timeIntervalSince($0) >= Self.grace } == true
    }.sorted {
      if $0.finishedAt != $1.finishedAt { return $0.finishedAt! < $1.finishedAt! }
      return $0.id.uuidString < $1.id.uuidString
    }
    let eligibleIDs = Set(eligible.map(\.id))
    protectedEntries = entries.filter { !eligibleIDs.contains($0.id) }
    var selected: [WorkflowHistoryEntry] = []
    var remaining = totalBytes
    for entry in eligible {
      if now.timeIntervalSince(entry.finishedAt!) >= Self.retention || remaining > budget {
        selected.append(entry)
        remaining -= entry.bytes
      }
    }
    candidates = selected
    remainingBytes = remaining
    reclaimedBytes = totalBytes - remaining
    overBudget = remaining > budget
  }
}

nonisolated public struct WorkflowHistoryCleanup: Equatable, Sendable {
  public init() {}
  public var removed: [UUID] = []
  public var failures: [String] = []
}

nonisolated public struct WorkflowHistory: Sendable {
  public let storage: WorkflowHistoryStorage
  public init(storage: WorkflowHistoryStorage) { self.storage = storage }

  public func preview(now: Date) throws -> WorkflowHistoryPreview {
    let lock = try storage.coordinate()
    defer { lock.close() }
    return try previewLocked(now: now)
  }

  private func previewLocked(now: Date) throws -> WorkflowHistoryPreview {
    var issues: [String] = []
    let directories = try storage.directories(onUnsafe: { issues.append("Not scanned: \($0.path)") })
    let counts = Dictionary(grouping: directories, by: { $0.lastPathComponent.lowercased() }).mapValues(\.count)
    let entries = directories.map { directory in
      let entry = inspect(directory, now: now)
      guard counts[directory.lastPathComponent.lowercased(), default: 0] > 1 else { return entry }
      return WorkflowHistoryEntry(
        id: entry.id, directory: entry.directory, name: entry.name, root: entry.root, state: entry.state,
        finishedAt: entry.finishedAt, bytes: entry.bytes, pinned: entry.pinned, protection: "Ambiguous run UUID")
    }
    return WorkflowHistoryPreview(entries: entries, now: now, issues: issues)
  }

  public func keep(_ directory: URL, pinned: Bool) throws {
    let lock = try storage.coordinate()
    defer { lock.close() }
    _ = try header(directory)
    let url = directory.appending(path: "keep.json")
    try storage.validate(url, allowMissing: true)
    try JSONEncoder().encode(pinned).write(to: url, options: .atomic)
  }

  public func cleanup(candidates: [UUID], now: Date) throws -> WorkflowHistoryCleanup {
    let lock = try storage.coordinate()
    defer { lock.close() }
    var result = WorkflowHistoryCleanup()
    // Never expand the user's confirmed set. Eligibility and budget can change after preview.
    let eligible = Set(try previewLocked(now: now).candidates.map(\.id))
    for id in candidates where eligible.contains(id) {
      do {
        guard let directory = try storage.find(id) else { continue }
        let occupancy = try storage.occupy(directory)
        defer { occupancy.close() }
        let entry = inspect(directory, now: now, checkOccupancy: false)
        guard entry.protection == nil, !entry.pinned,
          let finish = entry.finishedAt, now.timeIntervalSince(finish) >= WorkflowHistoryPreview.grace
        else { continue }
        _ = try storage.files(in: directory)
        // Keep failed units in their original place so the next inspection reports them.
        do { try FileManager.default.removeItem(at: directory) } catch {
          let marker = directory.appending(path: ".cleanup-failed")
          if (try? storage.validate(marker, allowMissing: true)) != nil {
            try? Data("Incomplete cleanup; inspect this run manually.".utf8).write(to: marker, options: .atomic)
          }
          throw error
        }
        result.removed.append(id)
      } catch {
        result.failures.append("\(id.uuidString): \(error)")
      }
    }
    return result
  }

  public func export(_ directory: URL, to destination: URL) throws {
    let lock = try storage.coordinate()
    let occupancy: WorkflowHistoryLock
    do { occupancy = try storage.occupy(directory) } catch {
      lock.close()
      throw error
    }
    lock.close()
    defer { occupancy.close() }
    let record = try header(directory)
    guard record.terminal, let finish = record.finishedAt, finish >= record.startedAt else {
      throw WorkflowHistoryError.protectedRun
    }
    let snapshot = try fingerprints(directory)
    let target = WorkflowHistoryStorage.canonicalURL(destination)
    guard !target.path.hasPrefix(storage.baseURL.path + "/"), target != storage.baseURL,
      !FileManager.default.fileExists(atPath: target.path)
    else { throw WorkflowHistoryError.unsafePath(target.path) }
    let temporary = target.deletingLastPathComponent().appending(path: ".workflow-export-\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", directory.path, temporary.path])
    try run("/usr/bin/unzip", ["-tqq", temporary.path])
    guard try fingerprints(directory) == snapshot else { throw WorkflowHistoryError.exportFailed }
    // Move fails if a destination appeared while the archive was being built.
    try FileManager.default.moveItem(at: temporary, to: target)
  }

  /// Rate limiting is shared by all app processes and uses the injected wall clock.
  public func maintenance(now: Date) throws -> WorkflowHistoryCleanup? {
    let lock = try storage.coordinate()
    let marker = storage.baseURL.appending(path: ".last-cleanup")
    if let data = try? storage.read(marker), let last = try? JSONDecoder().decode(Date.self, from: data),
      now >= last, now.timeIntervalSince(last) < 300
    {
      lock.close()
      return nil
    }
    do {
      try storage.validate(marker, allowMissing: true)
      try JSONEncoder().encode(now).write(to: marker, options: .atomic)
    } catch {
      lock.close()
      throw error
    }
    lock.close()
    let preview = try preview(now: now)
    return try cleanup(candidates: preview.candidates.map(\.id), now: now)
  }

  private func inspect(_ directory: URL, now: Date, checkOccupancy: Bool = true) -> WorkflowHistoryEntry {
    let id = UUID(uuidString: directory.lastPathComponent)!
    var name = id.uuidString
    var root = "Unknown execution root"
    var state = "unknown"
    var finished: Date?
    var bytes: Int64 = 0
    var pinned = false
    var protection: String?
    do {
      let files = try storage.files(in: directory)
      for file in files {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        bytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
      }
      if FileManager.default.fileExists(atPath: directory.appending(path: ".cleanup-failed").path) {
        throw WorkflowHistoryError.invalidRecord
      }
      let record = try header(directory)
      name = record.name
      root = record.root
      state = record.state
      finished = record.finishedAt
      let keepURL = directory.appending(path: "keep.json")
      if FileManager.default.fileExists(atPath: keepURL.path) {
        pinned = try JSONDecoder().decode(Bool.self, from: storage.read(keepURL))
      }
      if !record.terminal {
        protection = "Active or unknown state"
      } else if let finish = finished, finish >= record.startedAt {
        if now.timeIntervalSince(finish) < WorkflowHistoryPreview.grace { protection = "24-hour diagnostic window" }
      } else {
        protection = "Missing or invalid finish time"
      }
      if pinned { protection = "Keep Run" }
      if checkOccupancy {
        let lock = try storage.occupy(directory)
        lock.close()
      }
    } catch WorkflowHistoryError.occupied {
      protection = "In use by a Prowl process"
    } catch {
      protection = "Unreadable or unsafe record; size may be incomplete"
    }
    return WorkflowHistoryEntry(
      id: id, directory: directory, name: name, root: root, state: state, finishedAt: finished,
      bytes: bytes, pinned: pinned, protection: protection)
  }

  private func header(_ directory: URL) throws -> WorkflowHistoryMetadata {
    guard !FileManager.default.fileExists(atPath: directory.appending(path: ".cleanup-failed").path) else {
      throw WorkflowHistoryError.invalidRecord
    }
    return try WorkflowHistoryMetadata.read(directory: directory, storage: storage)
  }

  private func fingerprints(_ directory: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    for file in try storage.files(in: directory) {
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      var hash = SHA256()
      while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
      result[String(file.path.dropFirst(directory.path.count + 1))] = hash.finalize().map {
        String(format: "%02x", $0)
      }.joined()
    }
    return result
  }

  private func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw WorkflowHistoryError.exportFailed }
  }
}
