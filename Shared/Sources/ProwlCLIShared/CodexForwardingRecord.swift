import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

nonisolated public enum CodexForwardingRecordError: Error, Equatable, Sendable {
  case invalidRecord
}

nonisolated public final class CodexForwardingRecordLease: @unchecked Sendable {
  public let argv: [String]
  private let lock = NSLock()
  private var descriptor: Int32

  fileprivate init(argv: [String], descriptor: Int32) {
    self.argv = argv
    self.descriptor = descriptor
  }

  public func close() {
    lock.lock()
    let descriptor = self.descriptor
    self.descriptor = -1
    lock.unlock()
    if descriptor >= 0 {
      flock(descriptor, LOCK_UN)
      Darwin.close(descriptor)
    }
  }

  deinit {
    close()
  }
}

nonisolated public enum CodexForwardingRecordReader {
  public static let maximumRecordBytes = 64 * 1_024

  public static func open(_ locator: URL) throws -> CodexForwardingRecordLease {
    let parent = locator.deletingLastPathComponent()
    guard validOwnerOnlyDirectory(parent) else { throw CodexForwardingRecordError.invalidRecord }
    let descriptor = Darwin.open(
      locator.path(percentEncoded: false),
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { throw CodexForwardingRecordError.invalidRecord }
    var shouldClose = true
    defer {
      if shouldClose { Darwin.close(descriptor) }
    }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == geteuid(),
      metadata.st_mode & 0o777 == 0o600,
      metadata.st_size > 0,
      metadata.st_size <= maximumRecordBytes,
      flock(descriptor, LOCK_SH) == 0
    else {
      throw CodexForwardingRecordError.invalidRecord
    }
    var data = Data(count: Int(metadata.st_size))
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeMutableBytes { buffer in
        Darwin.read(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
      }
      guard count > 0 else {
        flock(descriptor, LOCK_UN)
        throw CodexForwardingRecordError.invalidRecord
      }
      offset += count
    }
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let values = object as? [Any],
      !values.isEmpty,
      values.count <= 128
    else {
      flock(descriptor, LOCK_UN)
      throw CodexForwardingRecordError.invalidRecord
    }
    var argv: [String] = []
    var totalBytes = 0
    for value in values {
      guard let value = value as? String, !value.contains("\0") else {
        flock(descriptor, LOCK_UN)
        throw CodexForwardingRecordError.invalidRecord
      }
      totalBytes += value.utf8.count
      guard totalBytes <= maximumRecordBytes else {
        flock(descriptor, LOCK_UN)
        throw CodexForwardingRecordError.invalidRecord
      }
      argv.append(value)
    }
    guard !argv[0].isEmpty else {
      flock(descriptor, LOCK_UN)
      throw CodexForwardingRecordError.invalidRecord
    }
    shouldClose = false
    return CodexForwardingRecordLease(argv: argv, descriptor: descriptor)
  }

  private static func validOwnerOnlyDirectory(_ url: URL) -> Bool {
    var metadata = stat()
    guard lstat(url.path(percentEncoded: false), &metadata) == 0 else { return false }
    return (metadata.st_mode & S_IFMT) == S_IFDIR
      && metadata.st_uid == geteuid()
      && metadata.st_mode & 0o777 == 0o700
  }
}
