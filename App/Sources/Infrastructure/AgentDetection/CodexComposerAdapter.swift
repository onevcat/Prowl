import Foundation

/// Codex's input box (verified 0.167.0, docs-ai 090): the dim placeholder reads as empty whatever
/// it says, a draft can span rows between the `›` row and the status footer, and Control-U kills
/// the current line without interrupting a running turn, so it is pressed until the box reads
/// empty. Escape does not clear and interrupts; Control-C quits an empty box. Codex takes Enter
/// right after a paste, so nothing waits for the echo.
nonisolated struct CodexComposerAdapter: AgentComposerAdapter {
  let agent = DetectedAgent.codex
  let name = "Codex"
  let clearPlan = AgentComposerClearPlan.killLines(key: "ctrl-u")

  func read(_ snapshot: AgentScreenSnapshot, styledSnapshot: () -> String?) -> AgentComposerReading {
    guard let styled = styledSnapshot() else { return .unrecognized }
    return CodexScreenProfile.composerReading(styledSnapshot: styled)
  }

  func pasteConfirmation(for purpose: AgentLinePurpose) -> AgentPasteConfirmation? { nil }
}
