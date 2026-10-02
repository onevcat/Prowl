import Foundation
import ProwlCLIShared
import XCTest

@testable import prowl

final class AgentReadOutputRendererTests: XCTestCase {
  func testResultOnlyDataIsVerbatimWithoutSyntheticNewline() {
    let payload = makePayload(
      outputMode: .resultOnly,
      status: .done,
      blocker: nil,
      result: AgentReadResult(state: .complete, text: "Final result")
    )

    XCTAssertEqual(OutputRenderer.agentReadResultOnlyData(payload), Data("Final result".utf8))
  }

  func testSnapshotTextIncludesStatusAndVerbatimBlocker() {
    let payload = makePayload(
      status: .blocked,
      blocker: "Do you want to proceed?\n❯ 1. Yes\n  2. No",
      result: AgentReadResult(
        state: .unavailable,
        error: AgentReadResultError(code: "SESSION_UNRESOLVED", message: "No trusted session.")
      )
    )

    let text = OutputRenderer.agentReadSnapshotText(payload)

    XCTAssertTrue(text.contains("Status: blocked"))
    XCTAssertTrue(text.contains("Result: unavailable (SESSION_UNRESOLVED)"))
    XCTAssertTrue(text.contains("## Blocker\nDo you want to proceed?\n❯ 1. Yes\n  2. No"))
  }

  private func makePayload(
    outputMode: AgentReadOutputMode = .snapshot,
    status: AgentsCommandStatus,
    blocker: String?,
    result: AgentReadResult
  ) -> AgentReadCommandPayload {
    AgentReadCommandPayload(
      outputMode: outputMode,
      target: ReadTarget(
        worktree: ReadTargetWorktree(id: "/tmp/project", name: "main", path: "/tmp/project", rootPath: "/tmp/project", kind: "git"),
        tab: ReadTargetTab(id: "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0", title: "Agent", selected: true),
        pane: ReadTargetPane(id: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764", title: "Claude", cwd: nil, focused: false)
      ),
      agent: AgentReadAgent(
        type: "claude",
        status: status,
        rawState: status.rawValue,
        detectionReason: "claude.blockedPrompt",
        lastChangedAt: "2026-08-11T12:00:00Z",
        session: nil
      ),
      blocker: blocker.map(AgentReadBlocker.init(text:)),
      result: result
    )
  }
}
