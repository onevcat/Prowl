import Foundation

/// Status of one symlink slot shared by the CLI installer (`/usr/local/bin/prowl`) and skill links.
nonisolated public enum SymlinkInstallStatus: Equatable, Sendable {
  case notInstalled
  /// A symlink that resolves to the expected source.
  case installed(path: String)
  /// A symlink to another live source (`destination` names it, resolved against the link's
  /// directory), or a real file/directory occupying the slot (`destination` is nil).
  case installedDifferentSource(path: String, destination: String?)
  /// A dangling symlink: `destination` no longer exists.
  case broken(path: String, destination: String)

  /// Where the occupying symlink points, when the slot holds a symlink that is not the expected source.
  public var destination: String? {
    switch self {
    case .installedDifferentSource(_, let destination): destination
    case .broken(_, let destination): destination
    case .notInstalled, .installed: nil
    }
  }
}

nonisolated public enum SymlinkInstallError: Error, Equatable, Sendable, LocalizedError {
  case sourceNotFound(path: String)
  /// A real file or directory occupies the slot; it is never replaced or removed.
  case conflict(path: String)
  case notInstalled(path: String)

  public var errorDescription: String? {
    switch self {
    case .sourceNotFound(let path):
      "Link source not found at \(path)."
    case .conflict(let path):
      "A file already exists at \(path) and is not a symlink. Remove it manually before continuing."
    case .notInstalled(let path):
      "No symlink found at \(path)."
    }
  }
}

/// Foundation-only symlink status/install/uninstall used by the app and the standalone CLI.
///
/// Real files and directories are never touched: `install` refuses them with `conflict` before
/// any mutation and `uninstall` removes symlinks only. Filesystem errors other than the typed
/// cases propagate unchanged so callers can escalate privileges when appropriate.
nonisolated public enum SymlinkInstaller {
  public static func status(linkPath: String, source: String) -> SymlinkInstallStatus {
    switch occupant(at: linkPath) {
    case .absent:
      return .notInstalled
    case .other:
      return .installedDifferentSource(path: linkPath, destination: nil)
    case .symlink(let destination):
      let resolvedDestination = resolve(destination, relativeTo: linkPath)
      guard FileManager.default.fileExists(atPath: resolvedDestination) else {
        return .broken(path: linkPath, destination: resolvedDestination)
      }
      if destination == source || realPath(resolvedDestination) == realPath(source) {
        return .installed(path: linkPath)
      }
      return .installedDifferentSource(path: linkPath, destination: resolvedDestination)
    }
  }

  /// Returns `true` when a real file or directory occupies the slot.
  public static func hasConflict(linkPath: String) -> Bool {
    if case .other = occupant(at: linkPath) {
      return true
    }
    return false
  }

  public static func install(source: String, linkPath: String) throws {
    guard FileManager.default.fileExists(atPath: source) else {
      throw SymlinkInstallError.sourceNotFound(path: source)
    }
    switch occupant(at: linkPath) {
    case .other:
      throw SymlinkInstallError.conflict(path: linkPath)
    case .symlink:
      try FileManager.default.removeItem(atPath: linkPath)
    case .absent:
      break
    }
    let directory = (linkPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: source)
  }

  public static func uninstall(linkPath: String) throws {
    switch occupant(at: linkPath) {
    case .absent:
      throw SymlinkInstallError.notInstalled(path: linkPath)
    case .other:
      throw SymlinkInstallError.conflict(path: linkPath)
    case .symlink:
      try FileManager.default.removeItem(atPath: linkPath)
    }
  }

  private enum Occupant {
    case absent
    case symlink(destination: String)
    case other
  }

  /// Inspects the slot itself without following a symlink, so dangling links are still visible.
  private static func occupant(at path: String) -> Occupant {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
      return .absent
    }
    guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
      let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    else {
      return .other
    }
    return .symlink(destination: destination)
  }

  private static func resolve(_ destination: String, relativeTo linkPath: String) -> String {
    guard !destination.hasPrefix("/") else { return destination }
    let directory = (linkPath as NSString).deletingLastPathComponent
    return (directory as NSString).appendingPathComponent(destination)
  }

  private static func realPath(_ path: String) -> String {
    URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
      .trimmingTrailingPathSeparator()
  }
}

extension String {
  /// Removes trailing path separators so directory URLs and link targets compare as plain paths.
  nonisolated public func trimmingTrailingPathSeparator() -> String {
    var value = self
    while value.count > 1, value.hasSuffix("/") {
      value.removeLast()
    }
    return value
  }
}
