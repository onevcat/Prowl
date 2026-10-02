import Foundation
import Testing

@testable import supacode

struct AgentScreenDetectionTests {
  @Test func unmigratedDetectorsReturnTheirExistingStateWithAStableReason() {
    let screen = "screen without a live rule"

    for agent in DetectedAgent.allCases where agent != .codex && agent != .claude {
      let detection = agent.detectScreen(in: screen)

      #expect(detection.state == agent.detectState(in: screen))
      #expect(detection.reason == .legacyDetector)
      #expect(detection.reason.identifier == "legacy.detector")
    }
  }

  @Test func transitionDiagnosticsIncludeTheStableReasonWithoutScreenText() {
    let diagnostic = AgentDetectionDiagnostic(
      tabId: TerminalTabID(rawValue: UUID()),
      childPID: nil,
      processGroupID: nil,
      job: nil,
      identified: nil,
      retainedAgent: .codex,
      raw: .blocked,
      reason: .matched(AgentScreenRuleID("codex.directoryTrust")),
      stabilized: .blocked
    )

    #expect(diagnostic.summary.contains("reason=codex.directoryTrust"))
    #expect(!diagnostic.summary.contains("screen="))
  }

  @Test func reasonIdentifiersDistinguishMatchesAndFallbacks() {
    let ruleID = AgentScreenRuleID("codex.directoryTrust")

    #expect(AgentScreenDetectionReason.matched(ruleID).identifier == "codex.directoryTrust")
    #expect(AgentScreenDetectionReason.noRuleMatched.identifier == "fallback.noRuleMatched")
  }
}
