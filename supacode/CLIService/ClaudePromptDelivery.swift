import Foundation

/// Public dispatch paste/submit sequencing. This observes the composer, not Agent idleness.
@MainActor
struct ClaudePromptDelivery {
  struct Observation: Equatable {
    let composer: String?
    let editingRevision: TimeInterval?
    let hasMarkedText: Bool
  }

  let observe: @MainActor () -> Observation?
  let insert: @MainActor (String) -> Bool
  let submit: @MainActor () -> Bool
  var clock: any Clock<Duration> = ContinuousClock()

  func deliver(_ text: String) async -> Bool {
    guard !Task.isCancelled, let before = observe(), before.composer == "", !before.hasMarkedText,
      insert(text), let pasted = observe()
    else { return false }
    // Code security: the insertion updates editing activity itself; any later edit invalidates this paste.
    for _ in 0..<20 {
      do { try await clock.sleep(for: .milliseconds(100)) } catch { return false }
      guard !Task.isCancelled, let current = observe(), !current.hasMarkedText,
        current.editingRevision == pasted.editingRevision
      else { return false }
      if let composer = current.composer, Self.confirmsPaste(composer, text: text) {
        return submit()
      }
    }
    return false
  }

  static func confirmsPaste(_ composer: String, text: String) -> Bool {
    let actual = composer.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let expected = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !actual.isEmpty, !expected.isEmpty else { return false }
    if actual == expected { return true }
    // Claude collapses multiline pasted content into a numbered marker in its input box.
    return actual.wholeMatch(of: /\[Pasted text #\d+ \+\d+ lines\]/) != nil
  }
}
