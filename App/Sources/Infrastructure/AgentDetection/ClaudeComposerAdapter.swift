import Foundation

/// Claude Code's input box (verified 2.1.319, docs-ai 090): a dim hint of any wording reads as
/// empty, a collapsed paste or image marker is a draft the screen cannot carry, and Control-S
/// (`chat:stash`) moves a draft aside, also while a turn runs; Control-S on the empty box brings
/// it back.
nonisolated struct ClaudeComposerAdapter: AgentComposerAdapter {
  let agent = DetectedAgent.claude
  let name = "Claude"
  let clearPlan = AgentComposerClearPlan.stash(key: "ctrl-s")

  func read(_ snapshot: AgentScreenSnapshot, styledSnapshot: () -> String?) -> AgentComposerReading {
    guard let contents = ClaudeScreenProfile.composerContents(in: snapshot, styledSnapshot: styledSnapshot) else {
      return .unrecognized
    }
    guard !contents.isEmpty else { return .empty }
    return .draft(.init(text: contents, isComplete: !ClaudeScreenProfile.showsAttachmentMarker(contents)))
  }

  func pasteConfirmation(for purpose: AgentLinePurpose) -> AgentPasteConfirmation? {
    switch purpose {
    case .dispatch: .required
    case .workflowMessage, .send: nil
    }
  }

  /// Claude collapses multiline pasted content into a numbered marker in its input box, and
  /// wraps text without spaces (CJK) between two characters.
  func confirmsPaste(_ composer: String, text: String) -> Bool {
    AgentComposerEcho.matchesExactly(composer, text: text)
      || AgentComposerEcho.collapsed(composer).wholeMatch(of: /\[Pasted text #\d+ \+\d+ lines\]/) != nil
      || AgentComposerEcho.matchesRows(of: composer, expected: text)
  }
}
