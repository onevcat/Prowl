import Foundation

@MainActor
protocol MirrorPaneSource {
  func panes() -> [MirrorPaneDescriptor]
  var supportsStyledScrollback: Bool { get }
  func snapshot(_ id: UUID, styledScrollback: Bool) throws -> MirrorFrame
  func snapshot(_ id: UUID) throws -> MirrorFrame
  func write(_ bytes: Data, to id: UUID) throws
  func textSnapshot(_ id: UUID) throws -> MirrorTextSnapshot
  func activeText(_ id: UUID) throws -> String
  var supportsViewportText: Bool { get }
  var supportsScrollState: Bool { get }
  var supportsRemoteScroll: Bool { get }
  func scroll(_ direction: MirrorMessage.ScrollDirection, to id: UUID) throws
  var supportsBoundedHistory: Bool { get }
  func boundedRetainedText(_ id: UUID) throws -> MirrorRetainedText
  /// The pane's agent state, for `conversation-v1` (docs-ai 087); nil when unknown.
  func agentState(_ id: UUID) -> PaneAgentState?
  /// Picks `choice` in the choice menu on the pane's screen, if it still is the prompt `id`
  /// (docs-ai 089 S4). `isLive` is asked before every key; once it is false, no key goes.
  func answerPrompt(
    _ id: String, choice: MirrorScreenPrompt.Target, in pane: UUID, isLive: @escaping @MainActor () -> Bool
  ) async -> MirrorPromptAnswer
  /// Presses allow-listed keys in an agent or shell pane (docs-ai 089 S5); nil when sent, else
  /// why not. `isLive` is asked before every key; once it is false, no key goes.
  func pressKeys(_ keys: [String], in pane: UUID, isLive: @escaping @MainActor () -> Bool) async -> String?
  /// Runs `text` as a command in a shell pane at its prompt: clears the line, inserts the text
  /// and presses Return. Nil when sent, else why not. `isLive` is asked before every step.
  func sendShellLine(_ text: String, in pane: UUID, isLive: @escaping @MainActor () -> Bool) async -> String?
}

struct MirrorTextSnapshot {
  let text: String
  var columns: UInt32 = 0
  var rows: UInt32 = 0
  var truncated = false
  var scrollBounds: MirrorScrollBounds?
}

extension MirrorPaneSource {
  var supportsStyledScrollback: Bool { false }
  func snapshot(_ id: UUID, styledScrollback: Bool) throws -> MirrorFrame { try snapshot(id) }
  func textSnapshot(_ id: UUID) throws -> MirrorTextSnapshot { .init(text: try activeText(id)) }
  var supportsViewportText: Bool { false }
  var supportsScrollState: Bool { false }
  var supportsRemoteScroll: Bool { false }
  func scroll(_ direction: MirrorMessage.ScrollDirection, to id: UUID) throws {
    throw MirrorProtocolError.invalidMessage
  }
  var supportsBoundedHistory: Bool { false }
  func boundedRetainedText(_ id: UUID) throws -> MirrorRetainedText {
    throw MirrorProtocolError.invalidMessage
  }
  func activeText(_ id: UUID) throws -> String { throw MirrorProtocolError.invalidMessage }
  func agentState(_ id: UUID) -> PaneAgentState? { nil }
  func pressKeys(_ keys: [String], in pane: UUID, isLive: @escaping @MainActor () -> Bool) -> String? {
    String(localized: "This Host cannot press keys from a mirror.")
  }
  func sendShellLine(_ text: String, in pane: UUID, isLive: @escaping @MainActor () -> Bool) -> String? {
    String(localized: "This Host cannot run shell commands from a mirror.")
  }
  func answerPrompt(
    _ id: String, choice: MirrorScreenPrompt.Target, in pane: UUID, isLive: @escaping @MainActor () -> Bool
  ) -> MirrorPromptAnswer {
    .refused(code: "PROMPT_UNSUPPORTED", message: String(localized: "This Host cannot answer prompts."))
  }
}

// A resize or a viewport move raced a read-only capture. Retry on the next poll.
enum MirrorPaneSourceError: Error {
  case captureChanged
}

/// The result of answering a screen prompt from a mirror (docs-ai 089 S4).
nonisolated enum MirrorPromptAnswer: Equatable, Sendable {
  case delivered(MirrorScreenPrompt.Option, permission: Bool)
  /// A box of a multi-select menu changed; the menu stays open until its Submit row is chosen.
  case toggled(MirrorScreenPrompt.Option)
  /// The Submit row of a multi-select menu was chosen.
  case submitted
  case refused(code: String, message: String)
}

/// The `choice` of a `promptRespond` command: an option's number, or `submit` for the Submit
/// row of a multi-select menu.
nonisolated enum MirrorPromptChoice {
  static let submit = "submit"
  static let submitOption = MirrorScreenPrompt.Option(number: 0, label: "Submit", detail: nil, isFreeform: false)

  static func target(_ choice: String) -> MirrorScreenPrompt.Target? {
    if choice == submit { return .submit }
    return Int(choice).map { .option($0) }
  }
}
