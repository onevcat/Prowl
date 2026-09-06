import CryptoKit
import Darwin
import Foundation

nonisolated public enum WorkflowHistoryError: Error, Equatable, Sendable {
  case unsafePath(String)
  case occupied
  case ambiguousRun(UUID)
  case invalidRecord
  case protectedRun
  case exportFailed
}

/// A separate open file description owns each lock, including within one process.
nonisolated public final class WorkflowHistoryLock: @unchecked Sendable {
  private let mutex = NSLock()
  private var descriptor: Int32

  init(_ url: URL) throws {
    descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw WorkflowHistoryError.unsafePath(url.path) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
      Darwin.close(descriptor)
      descriptor = -1
      throw WorkflowHistoryError.unsafePath(url.path)
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(descriptor)
      descriptor = -1
      throw WorkflowHistoryError.occupied
    }
  }

  public func close() {
    mutex.lock()
    defer { mutex.unlock() }
    guard descriptor >= 0 else { return }
    // A concurrently spawned child can briefly inherit the open description before exec.
    // Explicit unlock prevents that child from extending this owner's finished lease.
    _ = flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
    descriptor = -1
  }

  deinit { close() }
}

/// Sole owner of personal history paths. Callers inject an isolated base for tests.
nonisolated public struct WorkflowHistoryStorage: Equatable, Sendable {
  public let baseURL: URL

  public init(baseURL: URL) {
    self.baseURL = Self.canonicalURL(baseURL)
  }

  public static func canonicalURL(_ url: URL) -> URL {
    var ancestor = url.standardizedFileURL
    var suffix: [String] = []
    while true {
      if let resolved = realpath(ancestor.path, nil) {
        defer { free(resolved) }
        var result = URL(filePath: String(cString: resolved))
        for component in suffix.reversed() { result.append(path: component) }
        return result
      }
      if ancestor.path == "/" { return url.standardizedFileURL }
      suffix.append(ancestor.lastPathComponent)
      ancestor.deleteLastPathComponent()
    }
  }

  public static var user: Self {
    Self(baseURL: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".prowl/logs/workflow-runs"))
  }

  public func rootKey(_ root: URL) -> String {
    let canonical = Self.canonicalURL(root)
    let readable = String(
      canonical.lastPathComponent.unicodeScalars.map {
        CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character(String($0)) : "-"
      }.prefix(48))
    let hash = SHA256.hash(data: Data(canonical.path.utf8)).map { String(format: "%02x", $0) }.joined()
    return "\(readable.isEmpty ? "root" : readable)-\(hash)"
  }

  public func directory(root: URL, createdAt: Date, runID: UUID) -> URL {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = calendar.dateComponents([.year, .month], from: createdAt)
    let month = String(format: "%04d-%02d", parts.year!, parts.month!)
    return baseURL.appending(path: rootKey(root)).appending(path: month).appending(path: runID.uuidString)
  }

  public func prepare(_ directory: URL) throws {
    try validate(directory, allowMissing: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try validate(directory)
  }

  public func coordinate() throws -> WorkflowHistoryLock {
    try prepare(baseURL)
    return try WorkflowHistoryLock(baseURL.appending(path: ".coordination.lock"))
  }

  public func occupy(_ directory: URL) throws -> WorkflowHistoryLock {
    try validate(directory)
    return try WorkflowHistoryLock(directory.appending(path: ".occupancy.lock"))
  }

  public func validate(_ url: URL, allowMissing: Bool = false) throws {
    let path = url.path
    guard !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
      throw WorkflowHistoryError.unsafePath(path)
    }
    guard path == baseURL.path || path.hasPrefix(baseURL.path + "/") else {
      throw WorkflowHistoryError.unsafePath(path)
    }
    let suffix = String(path.dropFirst(baseURL.path.count))
    var current = baseURL
    for part in [""] + suffix.split(separator: "/").map(String.init) {
      if !part.isEmpty { current.append(path: part) }
      var info = stat()
      if lstat(current.path, &info) != 0 {
        if allowMissing && errno == ENOENT { continue }
        throw WorkflowHistoryError.unsafePath(current.path)
      }
      let type = info.st_mode & S_IFMT
      guard type == S_IFDIR || (type == S_IFREG && info.st_nlink == 1 && current.path == path) else {
        throw WorkflowHistoryError.unsafePath(current.path)
      }
    }
    guard Self.canonicalURL(url).path == path else {
      throw WorkflowHistoryError.unsafePath(path)
    }
  }

  public func directories(onUnsafe: (URL) -> Void = { _ in }) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: baseURL.path) else { return [] }
    try validate(baseURL)
    var result: [URL] = []
    for root in try children(baseURL) where !root.lastPathComponent.hasPrefix(".") {
      // Unsafe root/month entries are not traversed, even when they resemble a run.
      guard (try? validate(root)) != nil, isDirectory(root) else {
        onUnsafe(root)
        continue
      }
      for month in try children(root) {
        guard month.lastPathComponent.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil,
          (try? validate(month)) != nil, isDirectory(month)
        else {
          onUnsafe(month)
          continue
        }
        for run in try children(month) where UUID(uuidString: run.lastPathComponent) != nil {
          result.append(run)
        }
      }
    }
    return result.sorted { $0.path < $1.path }
  }

  public func find(_ id: UUID) throws -> URL? {
    let matches = try directories().filter { UUID(uuidString: $0.lastPathComponent) == id }
    guard matches.count <= 1 else { throw WorkflowHistoryError.ambiguousRun(id) }
    if let match = matches.first { try validate(match) }
    return matches.first
  }

  /// Never follows symbolic links or hard links. All run operations share this gate.
  public func files(in directory: URL) throws -> [URL] {
    try validate(directory)
    var pending = [directory]
    var files: [URL] = []
    while let parent = pending.popLast() {
      for child in try children(parent) {
        try validate(child)
        if isDirectory(child) { pending.append(child) } else { files.append(child) }
      }
    }
    return files.sorted { $0.path < $1.path }
  }

  public func read(_ url: URL, limit: Int = 1_048_576) throws -> Data {
    try validate(url)
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { throw WorkflowHistoryError.unsafePath(url.path) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_nlink == 1, info.st_size <= limit
    else { throw WorkflowHistoryError.unsafePath(url.path) }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw WorkflowHistoryError.unsafePath(url.path) }
    return data
  }

  public func readChunk(_ url: URL, offset: Int64) throws -> WorkflowHistoryChunk {
    try validate(url)
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { throw WorkflowHistoryError.unsafePath(url.path) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_nlink == 1, offset >= 0, offset <= info.st_size
    else { throw WorkflowHistoryError.unsafePath(url.path) }
    try handle.seek(toOffset: UInt64(offset))
    let data = try handle.read(upToCount: 64 * 1024) ?? Data()
    let next = offset + Int64(data.count)
    return WorkflowHistoryChunk(data: data, total: info.st_size, nextOffset: next < info.st_size ? next : nil)
  }

  private func children(_ directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
  }

  private func isDirectory(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
  }
}

nonisolated public struct WorkflowHistoryChunk: Sendable {
  public let data: Data
  public let total: Int64
  public let nextOffset: Int64?
}
