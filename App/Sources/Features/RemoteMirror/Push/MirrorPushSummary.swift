import Foundation

/// The line a push shows under the tab name when the phone has **Show Details** on (docs-ai
/// 095): what a blocked agent asks, or the start of a finished agent's last reply. It is
/// encrypted end to end like the rest of the content; without Show Details the phone shows
/// only the generic text.
nonisolated enum MirrorPushSummary {
  /// About two lines on a lock screen.
  static let maximumCharacters = 180
  /// Enough for the last turn of a long transcript; read only when a turn finishes.
  static let transcriptTailBytes = 256 * 1024

  /// The question on the agent's screen, with the first line of its detail, such as the
  /// command a permission asks about.
  static func question(onScreen text: String) -> String? {
    guard let prompt = MirrorScreenPrompt.parse(text) else { return nil }
    let detail = prompt.detail?.split(whereSeparator: \.isNewline).first.map(String.init)
    return oneLine([prompt.title, detail].compactMap { $0 }.joined(separator: " · "))
  }

  /// The start of the agent's last reply near the end of its transcript, or `nil`.
  static func lastReply(transcript url: URL, agent: DetectedAgent) -> String? {
    guard let pipeline = MirrorTranscriptPipeline(agent: agent),
      let handle = try? FileHandle(forReadingFrom: url)
    else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let start = size > UInt64(transcriptTailBytes) ? size - UInt64(transcriptTailBytes) : 0
    guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
    let events = pipeline.ingest(.replay(data, head: nil, startsMidRecord: start > 0)).events
    for event in events.reversed() {
      switch (event.kind, event.payload) {
      case (.turnCompleted, .turn(let turn)):
        if let reply = turn.lastMessage.flatMap({ oneLine($0.text) }) { return reply }
      case (.assistantMessage, .message(let message)):
        if let reply = oneLine(message.text.text) { return reply }
      default:
        continue
      }
    }
    return nil
  }

  /// One line for a notification: code and emphasis marks and heading marks removed,
  /// whitespace collapsed, at most `maximumCharacters`.
  static func oneLine(_ text: String) -> String? {
    let words = text.replacing("**", with: "").replacing("`", with: "")
      .split(whereSeparator: \.isWhitespace)
      .filter { word in !word.allSatisfy { $0 == "#" } }
    let line = words.joined(separator: " ")
    guard !line.isEmpty else { return nil }
    guard line.count > maximumCharacters else { return line }
    return String(line.prefix(maximumCharacters - 1)).trimmingCharacters(in: .whitespaces) + "…"
  }
}
