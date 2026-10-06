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

  /// The input box text on a plain screen: empty when there is no draft, nil when no input box is recognized.
  func contents(in snapshot: AgentScreenSnapshot) -> String? {
    switch self {
    case .claude: ClaudeScreenProfile.composerContents(in: snapshot)
    case .devin: DevinScreenProfile.composerContents(in: snapshot)
    }
  }

  /// Devin loses an Enter that arrives before it accepts the pasted draft.
  var dropsEarlyEnter: Bool { self == .devin }

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
  }

  let observe: @MainActor () -> Observation?
  let insert: @MainActor (String) -> Bool
  let submit: @MainActor () -> Bool
  var clock: any Clock<Duration> = ContinuousClock()
  var profile: AgentComposerProfile?

  func deliver(_ text: String) async -> AgentLineSubmission {
    guard !Task.isCancelled, let before = observe(), before.composer == "", !before.hasMarkedText,
      insert(text)
    else { return .notInserted }
    guard let pasted = observe() else { return .notSubmitted }
    // Code security: the insertion updates editing activity itself; any later edit invalidates this paste.
    for _ in 0..<20 {
      do { try await clock.sleep(for: .milliseconds(100)) } catch { return .notSubmitted }
      guard !Task.isCancelled, let current = observe(), !current.hasMarkedText,
        current.editingRevision == pasted.editingRevision
      else { return .notSubmitted }
      if let composer = current.composer, Self.confirmsPaste(composer, text: text, profile: profile) {
        return submit() ? .submitted : .notSubmitted
      }
    }
    return .notSubmitted
  }

  static func confirmsPaste(_ composer: String, text: String, profile: AgentComposerProfile? = nil) -> Bool {
    let actual = composer.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let expected = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !actual.isEmpty, !expected.isEmpty else { return false }
    if actual == expected { return true }
    switch profile {
    case .claude:
      // Claude collapses multiline pasted content into a numbered marker in its input box.
      return actual.wholeMatch(of: /\[Pasted text #\d+ \+\d+ lines\]/) != nil
    case .devin:
      // Devin can wrap inside a token. Only screen row boundaries may omit a space;
      // spaces within a row still have to match the inserted text.
      var remaining = expected[...]
      for row in composer.split(separator: "\n") {
        let segment = row.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        remaining = remaining.drop(while: \.isWhitespace)
        guard remaining.hasPrefix(segment) else { return false }
        remaining = remaining.dropFirst(segment.count)
      }
      return remaining.isEmpty
    case nil:
      return false
    }
  }
}
