import Foundation

enum CanvasCurrentDirectoryFormatter {
  static func displayPath(for path: String?, homePath: String = NSHomeDirectory()) -> String? {
    guard let path else { return nil }
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let normalizedPath = normalize(trimmed)
    let normalizedHome = normalize(homePath)

    if normalizedPath == normalizedHome {
      return "~"
    }
    if normalizedPath.hasPrefix("\(normalizedHome)/") {
      let suffix = normalizedPath.dropFirst(normalizedHome.count)
      return "~\(suffix)"
    }
    return normalizedPath
  }

  static func isDuplicateDirectoryTitle(
    _ title: String?,
    currentDirectoryPath: String?,
    homePath: String = NSHomeDirectory()
  ) -> Bool {
    guard let title, let currentDirectoryPath else { return false }
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedCurrentDirectory = currentDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty, !trimmedCurrentDirectory.isEmpty else { return false }

    let normalizedCurrentDirectory = normalize(trimmedCurrentDirectory)
    let normalizedTitle = normalize(expandedPath(trimmedTitle, homePath: homePath))

    if normalizedTitle == normalizedCurrentDirectory {
      return true
    }

    guard let displayDirectory = displayPath(for: trimmedCurrentDirectory, homePath: homePath) else {
      return false
    }
    let normalizedDisplayDirectory = normalize(expandedPath(displayDirectory, homePath: homePath))
    return normalizedTitle == normalizedDisplayDirectory
  }

  private static func normalize(_ path: String) -> String {
    guard path != "/" else { return "/" }
    var value = path
    while value.count > 1 && value.hasSuffix("/") {
      value.removeLast()
    }
    return value
  }

  private static func expandedPath(_ path: String, homePath: String) -> String {
    let normalizedHome = normalize(homePath)
    if path == "~" {
      return normalizedHome
    }
    if path.hasPrefix("~/") {
      let suffix = path.dropFirst(2)
      return "\(normalizedHome)/\(suffix)"
    }
    return path
  }
}
