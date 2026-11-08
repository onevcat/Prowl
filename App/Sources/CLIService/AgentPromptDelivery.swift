import Foundation
import ProwlCLIShared

/// Text Prowl inserted into an agent's input box and could not submit, because its echo could
/// not be confirmed in time. Only this text, with no input of any kind since the insertion
/// (`inputGeneration`, taken right after it), may be submitted later without inserting it again:
/// the screen alone cannot prove what a draft is (a collapsed paste marker hides its content,
/// whitespace is lost on screen, and history keys can swap the content behind the same marker).
nonisolated struct AgentUnsentLine: Equatable, Sendable {
  let text: String
  let inputGeneration: UInt64
}

/// Result of typing a line and pressing Enter.
nonisolated enum AgentLineSubmission: Equatable, Sendable {
  case submitted
  /// Nothing was typed.
  case notInserted
  /// The line may remain in the input box without Enter.
  case notSubmitted
}

/// Paste/submit sequencing. This observes the composer, not Agent idleness.
@MainActor
struct AgentPromptDelivery {
  struct Observation: Equatable {
    let composer: String?
    let editingRevision: TimeInterval?
    let hasMarkedText: Bool
    /// The surface's input count (`GhosttySurfaceView.inputGeneration`).
    var inputGeneration: UInt64?
  }

  let observe: @MainActor () -> Observation?
  let insert: @MainActor (String) -> Bool
  let submit: @MainActor () -> Bool
  var clock: any Clock<Duration> = ContinuousClock()
  var adapter: (any AgentComposerAdapter)?
  /// The line Prowl left unsent in this input box, if any.
  var unsent: AgentUnsentLine?
  /// Called when the inserted text may stay in the box without Enter, with the input state right
  /// after the insertion: the only state a later retry may resume.
  var onUnsent: (@MainActor (AgentUnsentLine) -> Void)?

  func deliver(_ text: String) async -> AgentLineSubmission {
    guard !Task.isCancelled, let before = observe(), !before.hasMarkedText else { return .notInserted }
    // An earlier delivery left exactly this text without Enter and nobody edited since: press
    // Enter instead of inserting it twice.
    if let composer = before.composer, !composer.isEmpty, let unsent,
      unsent.resumes(text, composer: composer, inputGeneration: before.inputGeneration, adapter: adapter)
    {
      return submit() ? .submitted : .notSubmitted
    }
    guard before.composer == "", insert(text) else { return .notInserted }
    guard let pasted = observe() else { return .notSubmitted }
    // Taken before any wait, so an edit that ends this delivery can never become its provenance.
    let left = pasted.inputGeneration.map { AgentUnsentLine(text: text, inputGeneration: $0) }
    func leftUnsent() -> AgentLineSubmission {
      if let left { onUnsent?(left) }
      return .notSubmitted
    }
    // Code security: the insertion updates editing activity itself; any later edit invalidates this paste.
    for _ in 0..<20 {
      do { try await clock.sleep(for: .milliseconds(100)) } catch { return leftUnsent() }
      // Any input since the insertion (also history keys, which leave the editing timestamp
      // alone) may have replaced the box: never press Enter on it.
      guard !Task.isCancelled, let current = observe(), !current.hasMarkedText,
        current.editingRevision == pasted.editingRevision, current.inputGeneration == pasted.inputGeneration
      else { return leftUnsent() }
      if let composer = current.composer, Self.confirmsPaste(composer, text: text, adapter: adapter) {
        return submit() ? .submitted : leftUnsent()
      }
    }
    return leftUnsent()
  }

  /// Whether the box shows `text` as the agent echoes a paste of it. Without an adapter only the
  /// same tokens count, whatever the whitespace between them.
  nonisolated static func confirmsPaste(
    _ composer: String, text: String, adapter: (any AgentComposerAdapter)? = nil
  ) -> Bool {
    guard let adapter else { return AgentComposerEcho.matchesExactly(composer, text: text) }
    return adapter.confirmsPaste(composer, text: text)
  }
}

extension AgentUnsentLine {
  /// Whether the input box still shows this unsent line as `text`: the same text was requested,
  /// no input of any kind reached the surface since Prowl inserted it, and the screen still echoes
  /// it.
  nonisolated func resumes(
    _ requested: String, composer: String, inputGeneration: UInt64?, adapter: (any AgentComposerAdapter)?
  ) -> Bool {
    requested == text && inputGeneration == self.inputGeneration
      && AgentPromptDelivery.confirmsPaste(composer, text: text, adapter: adapter)
  }
}
