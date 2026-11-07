import Foundation

/// Devin's input box (docs-ai 076): read from the plain screen, where its hint has a fixed
/// wording. Devin loses an Enter that arrives before it accepts the pasted draft, and no key has
/// been verified to clear a draft, so a draft keeps refusing delivery.
nonisolated struct DevinComposerAdapter: AgentComposerAdapter {
  let agent = DetectedAgent.devin
  let name = "Devin"
  let clearPlan = AgentComposerClearPlan.unsupported
  let dropsEarlyEnter = true

  func read(_ snapshot: AgentScreenSnapshot, styledSnapshot: () -> String?) -> AgentComposerReading {
    guard let contents = DevinScreenProfile.composerContents(in: snapshot) else { return .unrecognized }
    return contents.isEmpty ? .empty : .draft(.init(text: contents, isComplete: true))
  }

  func pasteConfirmation(for purpose: AgentLinePurpose) -> AgentPasteConfirmation? {
    switch purpose {
    case .dispatch, .workflowMessage: .required
    case .send: .whenComposerIsEmpty
    }
  }

  /// Devin can wrap inside a token.
  func confirmsPaste(_ composer: String, text: String) -> Bool {
    AgentComposerEcho.matchesRows(of: composer, expected: text)
  }
}
