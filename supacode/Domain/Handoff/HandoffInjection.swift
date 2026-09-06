import Foundation
import ProwlCLIShared

/// The one-line, self-contained request the UI types into the live source
/// agent. The agent composes the heredoc itself — nothing multi-line is ever
/// injected, so any TUI input box can take it.
nonisolated enum HandoffInjection {
  enum Purpose: Equatable, Sendable {
    case handOff(agent: String)
    case checkpoint
  }

  static func instruction(for purpose: Purpose, requestID: UUID) -> String {

    let sections = HandoffStore.briefingSections.joined(separator: ", ")
    let ask =
      switch purpose {
      case .handOff(let agent):
        "Please hand this task off to \(agent): run "
          + "`\(requestEnvironment(requestID))prowl handoff to \(agent) --brief -`"
      case .checkpoint:
        "Please checkpoint your progress for a later handoff: run "
          + "`\(requestEnvironment(requestID))prowl handoff save --brief -`"

      }
    return "[Prowl] \(ask) with your briefing on stdin as a heredoc — a markdown document "
      + "with the sections \(sections), written from your current working knowledge. "
      + "Keep Next Steps ordered and concrete. The command replies with guidance if the "
      + "briefing is incomplete."
  }

  private static func requestEnvironment(_ requestID: UUID) -> String {
    "\(HandoffInput.requestIDEnvironmentKey)=\(requestID.uuidString) "
  }
}
