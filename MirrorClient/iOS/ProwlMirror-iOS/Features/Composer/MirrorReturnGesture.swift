import Foundation

/// Remembers only the newline inserted by a physical Return, never trims a draft.
nonisolated struct MirrorReturnGesture {
  private struct Candidate {
    let text: String
    let selection: NSRange
    let insertedAt: Int
    let time: TimeInterval
  }
  private var candidate: Candidate?
  static let interval: TimeInterval = 0.350

  mutating func cancel() { candidate = nil }

  mutating func validate(text: String, selection: NSRange) {
    if candidate?.text != text || candidate?.selection != selection { cancel() }
  }

  mutating func record(
    before: String, selection: NSRange, after: String, afterSelection: NSRange,
    time: TimeInterval
  ) {
    cancel()
    guard let range = Range(selection, in: before), time.isFinite else { return }
    let expected = before.replacingCharacters(in: range, with: "\n")
    guard after == expected, afterSelection == NSRange(location: selection.location + 1, length: 0)
    else { return }
    candidate = Candidate(
      text: after, selection: afterSelection, insertedAt: selection.location, time: time)
  }

  mutating func consume(text: String, selection: NSRange, time: TimeInterval) -> String? {
    defer { cancel() }
    guard let candidate, candidate.text == text, candidate.selection == selection,
      time.isFinite, time >= candidate.time, time <= candidate.time + Self.interval,
      let range = Range(NSRange(location: candidate.insertedAt, length: 1), in: text)
    else { return nil }
    return text.replacingCharacters(in: range, with: "")
  }
}
