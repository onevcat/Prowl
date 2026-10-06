import Foundation

nonisolated extension AgentSessionProfile {
  /// Devin 3000.11.3 holds this descriptor in its ACP child, including while idle.
  /// Lock files survive exit: only open descriptors establish ownership, never a directory scan.
  static let devin = AgentSessionProfile(parsePath: { path in
    let marker = "/devin/cli/session_locks/"
    guard path.hasPrefix("/"), let range = path.range(of: marker, options: .backwards) else {
      return nil
    }
    let filename = path[range.upperBound...]
    guard filename.hasSuffix(".lock"), !filename.contains("/") else { return nil }
    let id = String(filename.dropLast(5))
    guard !id.isEmpty, id.utf8.count <= 256,
      id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
    else { return nil }
    let root = URL(filePath: String(path[..<range.upperBound])).deletingLastPathComponent()
    return AgentSession(
      id: id, transcriptPath: root.appending(path: "transcripts/\(id).json"), source: .openFile,
      confidence: .exact)
  })
}
