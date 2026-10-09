import Foundation

nonisolated extension AgentSessionProfile {
  /// Antigravity CLI 1.x holds `presence/<conversation>.lock` open for the life
  /// of an attached session (verified on 1.3.1). Lock files survive exit: only
  /// open descriptors establish ownership, never a directory scan.
  static let antigravity = AgentSessionProfile(parsePath: { path in
    let marker = "/.gemini/antigravity-cli/presence/"
    guard path.hasPrefix("/"), let range = path.range(of: marker, options: .backwards) else {
      return nil
    }
    let filename = path[range.upperBound...]
    guard filename.hasSuffix(".lock"), !filename.contains("/") else { return nil }
    let id = String(filename.dropLast(5))
    guard let uuid = UUID(uuidString: id) else { return nil }
    let root = URL(filePath: String(path[..<range.upperBound])).deletingLastPathComponent()
    return AgentSession(
      id: uuid.uuidString.lowercased(),
      transcriptPath: root.appending(path: "brain/\(id)/.system_generated/logs/transcript.jsonl"),
      source: .openFile,
      confidence: .exact)
  })
}
