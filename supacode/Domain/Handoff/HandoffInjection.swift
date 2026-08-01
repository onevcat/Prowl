import Foundation

/// The one-line, self-contained request the UI types into the live source
/// agent. The agent composes the heredoc itself — nothing multi-line is ever
/// injected, so any TUI input box can take it.
nonisolated enum HandoffInjection {
  /// Builds an injected request whose authorization and CLI selector name the
  /// same source pane. Profile targets carry only their stable UUID; mutable
  /// display names never become command identity.
  static func instruction(
    for expectation: HandoffRequestExpectation,
    requestID: UUID
  ) -> String {
    let sourcePane = expectation.sourcePaneID.uuidString
    let (description, command) =
      switch expectation.operation {
      case .checkpoint:
        (
          "checkpoint your progress for a later handoff",
          "prowl handoff save --pane \(sourcePane) --brief -"
        )
      case .handoff(target: .runtimeDefault(let agent)):
        (
          "hand this task off to \(agent.rawValue)",
          "prowl handoff to \(agent.rawValue) --pane \(sourcePane) --brief -"
        )
      case .handoff(target: .profile(let profileID)):
        (
          "hand this task off to the selected Agent Profile",
          "prowl handoff to --agent-profile-id \(profileID.uuidString) --pane \(sourcePane) --brief -"
        )
      }
    return instructionBody(
      ask: "Please \(description): run `\(requestEnvironment(requestID))\(command)`"
    )
  }

  private static func instructionBody(ask: String) -> String {
    let sections = HandoffStore.briefingSections.joined(separator: ", ")
    return "[Prowl] \(ask) with your briefing on stdin as a heredoc — a markdown document "
      + "with the sections \(sections), written from your current working knowledge. "
      + "Keep Next Steps ordered and concrete. The command replies with guidance if the "
      + "briefing is incomplete."
  }

  private static func requestEnvironment(_ requestID: UUID) -> String {
    "\(HandoffInput.requestIDEnvironmentKey)=\(requestID.uuidString) "
  }
}
