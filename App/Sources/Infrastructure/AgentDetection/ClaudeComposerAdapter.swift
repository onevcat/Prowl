import Foundation

/// Claude Code's input box (verified 2.1.319, docs-ai 090): a dim hint of any wording reads as
/// empty, a collapsed paste or image marker is a draft the screen cannot carry, and Control-S
/// (`chat:stash`) moves a typed draft or a collapsed paste aside, also while a turn runs;
/// Control-S on the empty box brings it back. An image attachment is not verified with
/// Control-S and keeps refusing. Claude brings a stashed draft back after the next message, so
/// a draft that must not come back is removed with Control-E then Control-U (verified 2.1.322):
/// Control-U removes only the text before the cursor, and the cursor can be anywhere. That is
/// verified for a draft of one row only; the text stays in Claude's kill ring (Control-Y).
nonisolated struct ClaudeComposerAdapter: AgentComposerAdapter {
  let agent = DetectedAgent.claude
  let name = "Claude"
  let clearPlan = AgentComposerClearPlan.stash(key: "ctrl-s")

  func discardPlan(for draft: AgentComposerDraft) -> AgentComposerClearPlan {
    draft.isComplete ? .killRow(endKey: "ctrl-e", killKey: "ctrl-u") : .unsupported
  }

  func read(_ snapshot: AgentScreenSnapshot, styledSnapshot: () -> String?) -> AgentComposerReading {
    guard let contents = ClaudeScreenProfile.composerContents(in: snapshot, styledSnapshot: styledSnapshot) else {
      return .unrecognized
    }
    guard !contents.isEmpty else { return .empty }
    // Rows are joined with newlines, which a soft wrap in the box does not have.
    let isComplete = !contents.contains("\n") && !ClaudeScreenProfile.showsAttachmentMarker(contents)
    return .draft(.init(text: contents, isComplete: isComplete))
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
