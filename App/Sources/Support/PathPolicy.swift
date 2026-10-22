import Foundation

nonisolated enum PathPolicy {
  static func normalizePath(
    _ rawPath: String,
    relativeTo baseURL: URL? = nil,
    resolvingSymlinks: Bool = true
  ) -> String? {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    let expanded = NSString(string: trimmed).expandingTildeInPath
    let url: URL
    if expanded.hasPrefix("/") {
      url = URL(fileURLWithPath: expanded)
    } else if let baseURL {
      url = baseURL.standardizedFileURL.appending(path: expanded, directoryHint: .inferFromPath)
    } else {
      url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: expanded, directoryHint: .inferFromPath)
    }
    return normalizeURL(url, resolvingSymlinks: resolvingSymlinks)
      .path(percentEncoded: false)
  }

  static func normalizeURL(
    _ url: URL,
    resolvingSymlinks: Bool = true
  ) -> URL {
    var normalized = url.standardizedFileURL
    if resolvingSymlinks,
      FileManager.default.fileExists(atPath: normalized.path(percentEncoded: false))
    {
      normalized = normalized.resolvingSymlinksInPath().standardizedFileURL
    }
    return normalized
  }

  /// Drops trailing slashes except the one of `/`. Path-based URL APIs append a
  /// slash only while a directory exists, so comparisons ignore it.
  static func trimmingTrailingSlashes(_ path: String) -> String {
    var path = path
    while path.count > 1, path.hasSuffix("/") {
      path.removeLast()
    }
    return path
  }

  static func contains(_ path: URL, in baseDirectory: URL) -> Bool {
    let normalizedPath = normalizeURL(path).pathComponents
    let normalizedBase = normalizeURL(baseDirectory).pathComponents
    guard normalizedPath.count >= normalizedBase.count else {
      return false
    }
    return Array(normalizedPath.prefix(normalizedBase.count)) == normalizedBase
  }
}
