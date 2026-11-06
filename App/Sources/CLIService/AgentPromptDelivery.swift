import Foundation

/// Why Prowl submits a line into an agent pane. The purpose decides how strictly the paste is confirmed.
nonisolated enum AgentLinePurpose: Sendable {
  /// `prowl agents dispatch`: refuses drafts and recent edits, then confirms every readable paste.
  case dispatch
  /// A workflow message: waits for the paste echo only where an early Enter is lost.
  case workflowMessage
  /// `prowl send` with Enter. It must still type into menus and after drafts, so it waits for
  /// the paste echo only where an early Enter is lost and the input box is empty.
  case send
}

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

/// An agent input box that Prowl can read from the screen.
nonisolated enum AgentComposerProfile: Equatable, Sendable {
  case claude
  case devin

  enum PasteConfirmation: Equatable, Sendable {
    /// Wait for the paste echo; fail when it cannot be confirmed.
    case required
    /// Wait for the paste echo when the input box is visible and empty; otherwise type directly.
    case whenComposerIsEmpty
  }

  init?(agent: DetectedAgent) {
    switch agent {
    case .claude: self = .claude
    case .devin: self = .devin
    default: return nil
    }
  }

  var name: String {
    switch self {
    case .claude: "Claude"
    case .devin: "Devin"
    }
  }

  /// Devin loses an Enter that arrives before it accepts the pasted draft.
  var dropsEarlyEnter: Bool { self == .devin }

  /// Nil when the input box can take `text`: it is empty, or it holds the line Prowl left there
  /// unsent (`unsent`), which is exactly `text` with no input since (`inputGeneration`).
  /// Otherwise why not, with the start of the draft so the person sees what is in the way.
  func draftRefusal(
    _ draft: String, delivering text: String?, unsent: AgentUnsentLine?, inputGeneration: UInt64?
  ) -> String? {
    if draft.isEmpty { return nil }
    if let text, let unsent, unsent.resumes(text, composer: draft, inputGeneration: inputGeneration, profile: self) {
      return nil
    }
    let collapsed = draft.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let excerpt = collapsed.count > 40 ? collapsed.prefix(40) + "…" : collapsed[...]
    return "\(name) has an existing draft or attachment (“\(excerpt)”). Clear it on Host before dispatching."
  }

  /// Nil means type the line and press Enter on the same main-actor turn.
  func pasteConfirmation(for purpose: AgentLinePurpose) -> PasteConfirmation? {
    switch purpose {
    case .dispatch: .required
    case .workflowMessage: dropsEarlyEnter ? .required : nil
    case .send: dropsEarlyEnter ? .whenComposerIsEmpty : nil
    }
  }
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
  var profile: AgentComposerProfile?
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
      unsent.resumes(text, composer: composer, inputGeneration: before.inputGeneration, profile: profile)
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
      if let composer = current.composer, Self.confirmsPaste(composer, text: text, profile: profile) {
        return submit() ? .submitted : leftUnsent()
      }
    }
    return leftUnsent()
  }

  nonisolated static func confirmsPaste(
    _ composer: String, text: String, profile: AgentComposerProfile? = nil
  ) -> Bool {
    let actual = composer.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let expected = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !actual.isEmpty, !expected.isEmpty else { return false }
    if actual == expected { return true }
    switch profile {
    case .claude:
      // Claude collapses multiline pasted content into a numbered marker in its input box, and
      // wraps text without spaces (CJK) between two characters.
      return actual.wholeMatch(of: /\[Pasted text #\d+ \+\d+ lines\]/) != nil
        || matchesRows(of: composer, expected: expected)
    case .devin:
      // Devin can wrap inside a token.
      return matchesRows(of: composer, expected: expected)
    case nil:
      return false
    }
  }

  /// Only screen row boundaries may omit a space; spaces within a row still have to match the
  /// inserted text.
  nonisolated private static func matchesRows(of composer: String, expected: String) -> Bool {
    var remaining = expected[...]
    for row in composer.split(separator: "\n") {
      let segment = row.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      remaining = remaining.drop(while: \.isWhitespace)
      guard remaining.hasPrefix(segment) else { return false }
      remaining = remaining.dropFirst(segment.count)
    }
    return remaining.isEmpty
  }
}

extension AgentUnsentLine {
  /// Whether the input box still shows this unsent line as `text`: the same text was requested,
  /// no input of any kind reached the surface since Prowl inserted it, and the screen still echoes
  /// it.
  nonisolated func resumes(
    _ requested: String, composer: String, inputGeneration: UInt64?, profile: AgentComposerProfile?
  ) -> Bool {
    requested == text && inputGeneration == self.inputGeneration
      && AgentPromptDelivery.confirmsPaste(composer, text: text, profile: profile)
  }
}
