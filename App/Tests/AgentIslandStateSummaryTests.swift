import Foundation
import Testing

@testable import supacode

struct AgentIslandStateSummaryTests {
  @Test func countsEveryStateInAttentionOrderAndOmitsEmptyOnes() {
    let summary = AgentIslandStateSummary(entries: [
      entry(state: .idle),
      entry(state: .working),
      entry(state: .blocked),
      entry(state: .idle),
      entry(state: .blocked),
    ])

    #expect(summary.items.map(\.state) == [.blocked, .working, .idle])
    #expect(summary.items.map(\.count) == [2, 1, 2])
  }

  @Test func emptyRosterHasNoItems() {
    #expect(AgentIslandStateSummary(entries: []).items.isEmpty)
  }

  @Test func accessibilityLabelSpellsOutEveryCount() {
    let summary = AgentIslandStateSummary(entries: [
      entry(state: .done),
      entry(state: .done),
      entry(state: .working),
    ])

    #expect(summary.accessibilityLabel == "2 done, 1 working")
  }

  @Test func everyStateHasItsOwnSymbol() {
    let symbols = [AgentDisplayState.working, .blocked, .done, .idle].map(\.islandSymbolName)

    #expect(Set(symbols).count == symbols.count)
  }

  private func entry(state: AgentDisplayState) -> ActiveAgentEntry {
    let id = UUID()
    return ActiveAgentEntry(
      id: id,
      worktreeID: "/repo/wt",
      worktreeName: "wt",
      workingDirectory: nil,
      tabID: TerminalTabID(rawValue: UUID()),
      paneTitle: "Agent",
      surfaceID: id,
      paneIndex: 1,
      iconLookupToken: DetectedAgent.codex.iconLookupToken,
      agent: .codex,
      rawState: state == .blocked ? .blocked : state == .working ? .working : .idle,
      displayState: state,
      lastChangedAt: Date(timeIntervalSince1970: 0)
    )
  }
}
