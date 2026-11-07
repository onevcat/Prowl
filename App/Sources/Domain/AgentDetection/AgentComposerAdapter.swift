import Foundation
import ProwlCLIShared

/// Why Prowl submits a line into an agent pane. The purpose decides how strictly the paste is confirmed.
nonisolated enum AgentLinePurpose: Sendable {
  /// `prowl agents dispatch` and `agents.input`: refuses drafts and recent edits, then confirms
  /// every readable paste.
  case dispatch
  /// A workflow message: waits for the paste echo only where an early Enter is lost.
  case workflowMessage
  /// `prowl send` with Enter. It must still type into menus and after drafts, so it waits for
  /// the paste echo only where an early Enter is lost and the input box is empty.
  case send
}

nonisolated enum AgentPasteConfirmation: Equatable, Sendable {
  /// Wait for the paste echo; fail when it cannot be confirmed.
  case required
  /// Wait for the paste echo when the input box is visible and empty; otherwise type directly.
  case whenComposerIsEmpty
}

/// Text in an agent's input box, as the screen shows it.
nonisolated struct AgentComposerDraft: Equatable, Sendable {
  let text: String
  /// True only when `text` is the draft exactly: one screen row with no marker. A draft that
  /// spans rows cannot tell a soft wrap from a newline, and a marker (a collapsed paste, an
  /// image) stands for content the screen does not show, so neither can be carried elsewhere.
  let isComplete: Bool

  var payload: AgentComposerDraftPayload { .init(text: text, isComplete: isComplete) }

  /// An image attachment chip (`[Image #1]`), which Claude Code and Codex render alike.
  var showsImage: Bool { text.contains(/\[Image #\d+\]/) }
}

/// What an agent's input box shows, read at the delivery boundary.
nonisolated enum AgentComposerReading: Equatable, Sendable {
  /// Nothing typed: an empty box, or only the dim hint the agent shows in one.
  case empty
  case draft(AgentComposerDraft)
  /// The box's boundaries could not be established; never an empty box.
  case unrecognized
}

/// The verified way to empty an agent's input box (docs-ai 090). Keys are `prowl key` tokens.
nonisolated enum AgentComposerClearPlan: Equatable, Sendable {
  /// One key moves the whole draft aside, and the same key on an empty box brings it back.
  case stash(key: String)
  /// One key removes the current line; pressed until the box reads empty.
  case killLines(key: String)
  /// Not verified for this agent: a draft refuses delivery.
  case unsupported

  var isSupported: Bool { self != .unsupported }

  /// How a cleared draft comes back on the Mac, or nil when it does not.
  var recovery: AgentDraftRecovery? {
    switch self {
    case .stash: .stash
    case .killLines, .unsupported: nil
    }
  }
}

/// One agent's input box: how to read it, how to clear it, and how its paste echo looks. A new
/// agent is one adapter plus screen fixtures; the delivery, clearing, and refusal code is shared.
nonisolated protocol AgentComposerAdapter: Sendable {
  var agent: DetectedAgent { get }
  var name: String { get }
  /// The box as the screen shows it. `styledSnapshot` is read only when the plain text cannot
  /// tell a dim hint from a typed draft.
  func read(_ snapshot: AgentScreenSnapshot, styledSnapshot: () -> String?) -> AgentComposerReading
  /// The verified way to empty the box of a typed draft.
  var clearPlan: AgentComposerClearPlan { get }
  /// The way to empty the box of this draft: `clearPlan`, or `unsupported` for content the key
  /// has not been verified against (an image attachment).
  func clearPlan(for draft: AgentComposerDraft) -> AgentComposerClearPlan
  /// The agent loses an Enter that arrives before it accepts the pasted text.
  var dropsEarlyEnter: Bool { get }
  /// Nil means type the line and press Enter on the same main-actor turn.
  func pasteConfirmation(for purpose: AgentLinePurpose) -> AgentPasteConfirmation?
  /// Whether the box shows `text` as the agent echoes a paste of it.
  func confirmsPaste(_ composer: String, text: String) -> Bool
}

nonisolated extension AgentComposerAdapter {
  var dropsEarlyEnter: Bool { false }

  /// Stashing or killing an image attachment is unverified for every agent (docs-ai 090).
  func clearPlan(for draft: AgentComposerDraft) -> AgentComposerClearPlan {
    draft.showsImage ? .unsupported : clearPlan
  }

  func confirmsPaste(_ composer: String, text: String) -> Bool {
    AgentComposerEcho.matchesExactly(composer, text: text)
      || AgentComposerEcho.matchesRows(of: composer, expected: text)
  }
}

/// How a pasted line may look on screen.
nonisolated enum AgentComposerEcho {
  static func collapsed(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// The same tokens, whatever the whitespace between them.
  static func matchesExactly(_ composer: String, text: String) -> Bool {
    let actual = collapsed(composer)
    let expected = collapsed(text)
    return !actual.isEmpty && !expected.isEmpty && actual == expected
  }

  /// Only screen row boundaries may omit a space; spaces within a row still have to match the
  /// inserted text.
  static func matchesRows(of composer: String, expected text: String) -> Bool {
    let expected = collapsed(text)
    guard !expected.isEmpty else { return false }
    var remaining = expected[...]
    for row in composer.split(separator: "\n") {
      let segment = collapsed(String(row))
      remaining = remaining.drop(while: \.isWhitespace)
      guard remaining.hasPrefix(segment) else { return false }
      remaining = remaining.dropFirst(segment.count)
    }
    return remaining.isEmpty
  }
}

nonisolated enum AgentComposerAdapters {
  /// The adapter for an agent whose input box Prowl can read, or nil: such an agent's lines are
  /// typed and entered directly, and its box is not checked for drafts.
  static func adapter(for agent: DetectedAgent) -> (any AgentComposerAdapter)? {
    switch agent {
    case .claude: ClaudeComposerAdapter()
    case .codex: CodexComposerAdapter()
    case .devin: DevinComposerAdapter()
    default: nil
    }
  }
}
