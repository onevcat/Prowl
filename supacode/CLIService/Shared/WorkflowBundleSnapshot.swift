import CryptoKit
import Darwin
import Foundation

/// Captures bytes before approval/copy so source edits cannot change the reviewed candidate.
nonisolated public struct WorkflowBundleSnapshot: Equatable, Sendable {
  public enum ChangeKind: String, Sendable { case added, modified, removed }

  public struct Change: Equatable, Sendable {
    public let path: String
    public let kind: ChangeKind
    public init(path: String, kind: ChangeKind) {
      self.path = path
      self.kind = kind
    }
  }

  public let source: URL
  public let files: [String: Data]
  public let fingerprint: String
  public var fileFingerprints: [String: String] { files.mapValues { Self.hash($0) } }

  public static func read(_ source: URL, fileManager: FileManager = .default) throws -> Self {
    let rootAttributes = try fileManager.attributesOfItem(atPath: source.standardizedFileURL.path)
    guard rootAttributes[.type] as? FileAttributeType == .typeDirectory else {
      throw WorkflowExpressionError.type("Bundle must be a directory, without symlinks.")
    }
    guard let canonical = realpath(source.path, nil) else { throw POSIXError(.ENOENT) }
    defer { free(canonical) }
    let root = URL(filePath: String(cString: canonical), directoryHint: .isDirectory)
    var pending = try fileManager.contentsOfDirectory(atPath: root.path).sorted()
    var files: [String: Data] = [:]
    var seen: Set<String> = []
    var totalBytes = 0
    while let path = pending.popLast() {
      let file = root.appending(path: path)
      let normalized = path.precomposedStringWithCanonicalMapping.lowercased()
      guard seen.insert(normalized).inserted, seen.count <= 2048 else {
        throw WorkflowExpressionError.limit("Bundle contains colliding paths or more than 2048 entries.")
      }
      let attributes = try fileManager.attributesOfItem(atPath: file.path)
      let type = attributes[.type] as? FileAttributeType
      if type == .typeDirectory {
        let children = try fileManager.contentsOfDirectory(atPath: file.path)
        pending += children.map { path + "/" + $0 }
        continue
      }
      guard type == .typeRegular else {
        throw WorkflowExpressionError.type("Bundle entry '\(path)' must be a regular file; symlinks are not supported.")
      }
      let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
      guard size <= 16 * 1024 * 1024 - totalBytes else {
        throw WorkflowExpressionError.limit("Bundle exceeds 16 MiB.")
      }
      let data = try Data(contentsOf: file)
      totalBytes += data.count
      guard totalBytes <= 16 * 1024 * 1024 else { throw WorkflowExpressionError.limit("Bundle exceeds 16 MiB.") }
      files[path] = data
    }
    guard files["workflow.yaml"] != nil else { throw WorkflowExpressionError.missing("workflow.yaml") }
    var digest = SHA256()
    for path in files.keys.sorted() {
      guard let data = files[path] else { continue }
      digest.update(data: Data("\(path.utf8.count):\(path):\(data.count):".utf8))
      digest.update(data: data)
    }
    let fingerprint = digest.finalize().map { String(format: "%02x", $0) }.joined()
    return Self(source: root.resolvingSymlinksInPath(), files: files, fingerprint: fingerprint)
  }

  public func changes(from previous: Self) -> [Change] {
    Self.changes(current: fileFingerprints, previous: previous.fileFingerprints)
  }

  public static func changes(current: [String: String], previous: [String: String]) -> [Change] {
    Set(current.keys).union(previous.keys).sorted().compactMap { path in
      if current[path] == previous[path] { return nil }
      let kind: ChangeKind = current[path] == nil ? .removed : previous[path] == nil ? .added : .modified
      return Change(path: path, kind: kind)
    }
  }

  public func copy(to destination: URL, fileManager: FileManager = .default) throws {
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw WorkflowExpressionError.type("Definition destination already exists.")
    }
    try fileManager.createDirectory(
      at: destination, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    for path in files.keys.sorted() {
      guard let data = files[path] else { continue }
      let target = destination.appending(path: path)
      try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: target, options: .atomic)
      try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
    }
    guard try Self.read(destination).fingerprint == fingerprint else {
      throw WorkflowExpressionError.type("Definition copy failed integrity verification.")
    }
  }

  private static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
