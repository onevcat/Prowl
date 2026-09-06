import Foundation
import ProwlCLIShared

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

nonisolated struct CodexForwardingRecord: Equatable, Sendable {
  let locator: URL
}

@MainActor
final class CodexForwardingRecordStore {
  private let baseDirectory: URL
  private let sessionDirectory: URL
  private let retirementGrace: TimeInterval
  private let orphanMaximumAge: TimeInterval
  private let now: @MainActor () -> Date
  private let retirementClock: any Clock<Duration>
  private var sessionLockDescriptor: Int32 = -1
  private var retired: [URL: Date] = [:]
  private var cleanupTask: Task<Void, Never>?

  init(
    baseDirectory: URL,
    retirementGrace: TimeInterval = 2,
    orphanMaximumAge: TimeInterval = 24 * 60 * 60,
    now: @escaping @MainActor () -> Date = Date.init,
    retirementClock: any Clock<Duration> = ContinuousClock()
  ) throws {
    self.baseDirectory = baseDirectory.standardizedFileURL
    self.retirementGrace = max(0, retirementGrace)
    self.orphanMaximumAge = max(0, orphanMaximumAge)
    self.now = now
    self.retirementClock = retirementClock
    try Self.ensureOwnerOnlyDirectory(self.baseDirectory)
    sessionDirectory = self.baseDirectory.appending(
      path: "session-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try Self.ensureOwnerOnlyDirectory(sessionDirectory)
    sessionLockDescriptor = try Self.acquireSessionOwnerLock(in: sessionDirectory)
    try FileManager.default.setAttributes(
      [.modificationDate: now()],
      ofItemAtPath: sessionDirectory.path(percentEncoded: false)
    )
  }

  isolated deinit {
    if sessionLockDescriptor >= 0 {
      flock(sessionLockDescriptor, LOCK_UN)
      Darwin.close(sessionLockDescriptor)
    }
  }

  func create(argv: [String]) throws -> CodexForwardingRecord {
    guard !argv.isEmpty, !argv[0].isEmpty, argv.count <= 128,
      argv.allSatisfy({ !$0.contains("\0") }),
      let data = try? JSONSerialization.data(withJSONObject: argv),
      data.count <= CodexForwardingRecordReader.maximumRecordBytes
    else {
      throw CodexForwardingRecordError.invalidRecord
    }
    return try createPrivateFile(data)
  }

  /// Owner-only storage for any managed-hook payload that must live on disk for the lifetime
  /// of one launch. Besides Codex forwarding argv, S3b writes Droid's merged settings here:
  /// that file can contain user secrets such as `customModels[].apiKey`, so it needs the same
  /// `0700`/`0600` guarantees, cross-instance session lock, and orphan sweep.
  func createPrivateFile(_ data: Data) throws -> CodexForwardingRecord {
    guard data.count <= CodexForwardingRecordReader.maximumRecordBytes else {
      throw CodexForwardingRecordError.invalidRecord
    }
    let locator = sessionDirectory.appending(
      path: "record-\(UUID().uuidString).json",
      directoryHint: .notDirectory
    )
    let temporary = sessionDirectory.appending(
      path: ".record-\(UUID().uuidString).tmp",
      directoryHint: .notDirectory
    )
    let temporaryPath = temporary.path(percentEncoded: false)
    let descriptor = Darwin.open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw CodexForwardingRecordError.invalidRecord }
    var succeeded = false
    defer {
      Darwin.close(descriptor)
      if !succeeded {
        try? FileManager.default.removeItem(at: temporary)
        try? FileManager.default.removeItem(at: locator)
      }
    }
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(
          descriptor,
          buffer.baseAddress?.advanced(by: offset),
          buffer.count - offset
        )
        guard count > 0 else { throw CodexForwardingRecordError.invalidRecord }
        offset += count
      }
    }
    guard fsync(descriptor) == 0,
      rename(temporaryPath, locator.path(percentEncoded: false)) == 0,
      chmod(locator.path(percentEncoded: false), 0o600) == 0
    else {
      throw CodexForwardingRecordError.invalidRecord
    }
    succeeded = true
    try FileManager.default.setAttributes(
      [.modificationDate: now()],
      ofItemAtPath: sessionDirectory.path(percentEncoded: false)
    )
    return CodexForwardingRecord(locator: locator)
  }

  func discardUnexposed(_ record: CodexForwardingRecord) {
    retired.removeValue(forKey: record.locator)
    try? FileManager.default.removeItem(at: record.locator)
  }

  func retire(_ record: CodexForwardingRecord) {
    retired[record.locator] = now().addingTimeInterval(retirementGrace)
    scheduleCleanupIfNeeded()
  }

  func cleanupRetired() {
    let date = now()
    for (locator, eligibleAt) in retired where date >= eligibleAt {
      if removeIfExclusivelyLeased(locator) {
        retired.removeValue(forKey: locator)
      }
    }
  }

  private func scheduleCleanupIfNeeded() {
    guard cleanupTask == nil else { return }
    let clock = retirementClock
    let milliseconds = max(100, Int(retirementGrace * 1_000))
    cleanupTask = Task { @MainActor [weak self] in
      while let self, !retired.isEmpty {
        do {
          try await clock.sleep(for: .milliseconds(milliseconds))
        } catch {
          break
        }
        cleanupRetired()
      }
      self?.cleanupTask = nil
    }
  }

  func sweepOrphans() {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: baseDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else { return }
    let cutoff = now().addingTimeInterval(-orphanMaximumAge)
    for directory in entries where directory.lastPathComponent.hasPrefix("session-") {
      guard directory.standardizedFileURL != sessionDirectory.standardizedFileURL,
        validOwnerOnlyDirectory(directory),
        let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
        values.isDirectory == true,
        let modified = values.contentModificationDate,
        modified <= cutoff
      else { continue }
      removeOrphanDirectoryIfUnlocked(directory)
    }
  }

  private func removeOrphanDirectoryIfUnlocked(_ directory: URL) {
    guard let descriptor = try? Self.acquireSessionOwnerLock(in: directory) else { return }
    defer {
      flock(descriptor, LOCK_UN)
      Darwin.close(descriptor)
    }
    guard canExclusivelyLeaseEveryRecord(in: directory) else { return }
    try? FileManager.default.removeItem(at: directory)
  }

  private func canExclusivelyLeaseEveryRecord(in directory: URL) -> Bool {
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else { return false }
    var descriptors: [Int32] = []
    defer {
      for descriptor in descriptors {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
      }
    }
    for file in files {
      let descriptor = Darwin.open(file.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW)
      guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        if descriptor >= 0 { Darwin.close(descriptor) }
        return false
      }
      descriptors.append(descriptor)
    }
    return true
  }

  private func removeIfExclusivelyLeased(_ locator: URL) -> Bool {
    let path = locator.path(percentEncoded: false)
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
    if descriptor < 0 { return unlink(path) == 0 || errno == ENOENT }
    defer { Darwin.close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
    defer { flock(descriptor, LOCK_UN) }
    return unlink(path) == 0 || errno == ENOENT
  }

  private static func acquireSessionOwnerLock(in directory: URL) throws -> Int32 {
    let lockURL = directory.appending(path: ".owner.lock", directoryHint: .notDirectory)
    let descriptor = Darwin.open(
      lockURL.path(percentEncoded: false),
      O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
      0o600
    )
    guard descriptor >= 0 else { throw CodexForwardingRecordError.invalidRecord }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == geteuid(),
      metadata.st_mode & 0o777 == 0o600,
      flock(descriptor, LOCK_EX | LOCK_NB) == 0
    else {
      Darwin.close(descriptor)
      throw CodexForwardingRecordError.invalidRecord
    }
    return descriptor
  }

  private static func ensureOwnerOnlyDirectory(_ directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directory.path(percentEncoded: false)
    )
    guard validOwnerOnlyDirectory(directory) else {
      throw CodexForwardingRecordError.invalidRecord
    }
  }

  private static func validOwnerOnlyDirectory(_ directory: URL) -> Bool {
    var metadata = stat()
    guard lstat(directory.path(percentEncoded: false), &metadata) == 0 else { return false }
    return (metadata.st_mode & S_IFMT) == S_IFDIR
      && metadata.st_uid == geteuid()
      && metadata.st_mode & 0o777 == 0o700
  }

  private func validOwnerOnlyDirectory(_ directory: URL) -> Bool {
    Self.validOwnerOnlyDirectory(directory)
  }
}
