import Foundation

protocol CanvasDirectoryFileSystem: Sendable {
  func canonicalPath(for normalizedDisplayPath: String, homePath: String) async -> String?
  func parentIdentity(forCanonicalParentPath parentPath: String) async -> String?
  func siblingDirectoryNames(inCanonicalParentPath parentPath: String) async throws -> [String]
}

struct LiveCanvasDirectoryFileSystem: CanvasDirectoryFileSystem {
  func canonicalPath(for normalizedDisplayPath: String, homePath: String) async -> String? {
    guard let absolutePath = expandedAbsolutePath(for: normalizedDisplayPath, homePath: homePath) else {
      return nil
    }
    let standardizedPath = URL(filePath: absolutePath, directoryHint: .isDirectory)
      .standardizedFileURL
      .path(percentEncoded: false)
    return normalizeAbsolutePath(standardizedPath)
  }

  func parentIdentity(forCanonicalParentPath parentPath: String) async -> String? {
    let parentURL = URL(filePath: parentPath, directoryHint: .isDirectory)
    do {
      let values = try parentURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
      guard let identifier = values.fileResourceIdentifier else { return nil }
      return String(describing: identifier)
    } catch {
      return nil
    }
  }

  func siblingDirectoryNames(inCanonicalParentPath parentPath: String) async throws -> [String] {
    let parentURL = URL(filePath: parentPath, directoryHint: .isDirectory)
    let entries = try FileManager.default.contentsOfDirectory(
      at: parentURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: []
    )
    var siblings: [String] = []
    for entry in entries {
      let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
      guard values.isDirectory == true else { continue }
      siblings.append(entry.lastPathComponent)
    }
    return siblings.sorted()
  }

  private func expandedAbsolutePath(for path: String, homePath: String) -> String? {
    let normalizedHomePath = normalizeAbsolutePath(homePath)
    if path == "~" {
      return normalizedHomePath
    }
    if path.hasPrefix("~/") {
      let suffix = path.dropFirst(2)
      return normalizeAbsolutePath("\(normalizedHomePath)/\(suffix)")
    }
    if path.hasPrefix("/") {
      return normalizeAbsolutePath(path)
    }
    return nil
  }

  private func normalizeAbsolutePath(_ path: String) -> String {
    guard path != "/" else { return "/" }
    var value = path
    while value.count > 1, value.hasSuffix("/") {
      value.removeLast()
    }
    return value
  }
}
