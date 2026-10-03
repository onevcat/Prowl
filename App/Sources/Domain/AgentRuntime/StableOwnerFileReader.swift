import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

nonisolated enum StableOwnerFileReadResult: Equatable, Sendable {
  case stable(Data)
  case changed
  case oversized
  case unreadable
}

nonisolated enum StableOwnerFileReader {
  static func read(
    _ url: URL,
    maximumBytes: Int,
    afterRead: () -> Void = {}
  ) -> StableOwnerFileReadResult {
    let path = url.path(percentEncoded: false)
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { return .unreadable }
    defer { Darwin.close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0,
      (before.st_mode & S_IFMT) == S_IFREG,
      before.st_uid == geteuid(),
      before.st_size >= 0
    else { return .unreadable }
    guard before.st_size <= maximumBytes else { return .oversized }

    var data = Data(count: Int(before.st_size))
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeMutableBytes { buffer in
        Darwin.read(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
      }
      guard count > 0 else { return .unreadable }
      offset += count
    }
    afterRead()

    var descriptorAfter = stat()
    var pathAfter = stat()
    guard fstat(descriptor, &descriptorAfter) == 0,
      lstat(path, &pathAfter) == 0,
      sameSnapshot(before, descriptorAfter),
      sameSnapshot(descriptorAfter, pathAfter),
      (pathAfter.st_mode & S_IFMT) == S_IFREG,
      pathAfter.st_uid == geteuid()
    else { return .changed }
    return .stable(data)
  }

  private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev
      && lhs.st_ino == rhs.st_ino
      && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
  }
}
