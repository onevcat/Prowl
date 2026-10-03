import Foundation

nonisolated enum DiffFileStatus: Hashable, Sendable {
  case modified
  case added
  case deleted
  case renamed
  case copied
  case unknown
}

nonisolated struct DiffChangedFile: Identifiable, Hashable, Sendable {
  let status: DiffFileStatus
  let oldPath: String?
  let newPath: String?

  var id: String { displayPath }

  var displayPath: String { newPath ?? oldPath ?? "" }

  var displayName: String {
    URL(fileURLWithPath: displayPath).lastPathComponent
  }

  var directoryPath: String {
    let url = URL(fileURLWithPath: displayPath)
    let dir = url.deletingLastPathComponent().relativePath
    return dir == "." ? "" : dir
  }

  var statusSymbol: String {
    switch status {
    case .modified: "M"
    case .added: "A"
    case .deleted: "D"
    case .renamed: "R"
    case .copied: "C"
    case .unknown: "?"
    }
  }

  static func parseNameStatus(_ output: String) -> [DiffChangedFile] {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    return trimmed.split(whereSeparator: \.isNewline).compactMap { line in
      let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard let statusStr = parts.first else { return nil }
      let code = String(statusStr)

      if code.hasPrefix("R") {
        return DiffChangedFile(
          status: .renamed,
          oldPath: parts.count > 1 ? String(parts[1]) : nil,
          newPath: parts.count > 2 ? String(parts[2]) : nil,
        )
      } else if code.hasPrefix("C") {
        return DiffChangedFile(
          status: .copied,
          oldPath: parts.count > 1 ? String(parts[1]) : nil,
          newPath: parts.count > 2 ? String(parts[2]) : nil,
        )
      }

      let filePath = parts.count > 1 ? String(parts[1]) : nil
      let status: DiffFileStatus =
        switch code {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "T": .modified
        default: .unknown
        }

      return DiffChangedFile(
        status: status,
        oldPath: status == .added ? nil : filePath,
        newPath: status == .deleted ? nil : filePath,
      )
    }
  }
}
