import Foundation
import Testing

@testable import supacode

struct AgentIslandAttentionCollectionTests {
  @Test func singleEntryUsesCompactSingleColumnLayout() {
    let layout = AgentIslandAttentionLayout.layout(entryCount: 1)

    #expect(layout.columnCount == 1)
    #expect(layout.rowCount == 1)
    #expect(layout.width == 286)
    #expect(layout.viewportHeight == 52)
    #expect(layout.visibleEntryCount == 1)
    #expect(layout.overflowCount == 0)
  }

  @Test func collectionShowsAtMostTwoColumnsAndThreeRows() {
    let layout = AgentIslandAttentionLayout.layout(entryCount: 5)

    #expect(layout.columnCount == 2)
    #expect(layout.rowCount == 3)
    #expect(layout.width == 380)
    #expect(layout.viewportHeight == 168)
    #expect(layout.visibleEntryCount == 5)
    #expect(layout.overflowCount == 0)
  }

  @Test func collectionOverflowTracksRemindersBeyondTheSixVisibleCards() {
    let layout = AgentIslandAttentionLayout.layout(entryCount: 7)

    #expect(layout.columnCount == 2)
    #expect(layout.rowCount == 3)
    #expect(layout.width == 380)
    #expect(layout.viewportHeight == 168)
    #expect(layout.visibleEntryCount == 6)
    #expect(layout.overflowCount == 1)
    #expect(AgentIslandAttentionLayout.layout(entryCount: 9).overflowCount == 3)
  }

  @Test func blockedPresentationUsesSharedLabelAndResolvedWorktree() {
    let presentation = AgentIslandAttentionPresentation.presentation(
      for: entry(state: .blocked, paneTitle: "Approval"),
      rowDisplay: ActiveAgentRowDisplay(
        repositoryName: "Prowl",
        branchName: "feature/island",
        color: nil,
        directory: nil
      ),
      showTabTitles: false
    )

    #expect(presentation.statusLabel == "Blocked")
    #expect(presentation.repositoryName == "Prowl")
    #expect(presentation.subtitle == "feature/island")
  }

  @Test func donePresentationMatchesThePanelTabTitleSetting() {
    let presentation = AgentIslandAttentionPresentation.presentation(
      for: entry(state: .done, paneTitle: "Implementation"),
      rowDisplay: ActiveAgentRowDisplay(
        repositoryName: "Prowl",
        branchName: "feature/island",
        color: nil,
        directory: nil
      ),
      showTabTitles: true
    )

    #expect(presentation.statusLabel == "Done")
    #expect(presentation.repositoryName == "Prowl")
    #expect(presentation.subtitle == "Implementation")
  }

  @Test func presentationUsesTheSharedWorkflowBadgeBeforeBranchOrTabTitle() {
    let presentation = AgentIslandAttentionPresentation.presentation(
      for: entry(state: .blocked, paneTitle: "Implementation"),
      rowDisplay: ActiveAgentRowDisplay(
        repositoryName: "Prowl",
        branchName: "feature/island",
        color: nil,
        directory: nil
      ),
      showTabTitles: true,
      workflowBadge: "reviewer"
    )

    #expect(presentation.subtitle == "reviewer")
  }

  private func entry(state: AgentDisplayState, paneTitle: String) -> ActiveAgentEntry {
    let id = UUID()
    return ActiveAgentEntry(
      id: id,
      worktreeID: "/repo/wt",
      worktreeName: "wt",
      workingDirectory: nil,
      tabID: TerminalTabID(rawValue: UUID()),
      paneTitle: paneTitle,
      surfaceID: id,
      paneIndex: 1,
      iconLookupToken: DetectedAgent.codex.iconLookupToken,
      agent: .codex,
      rawState: state == .blocked ? .blocked : .idle,
      displayState: state,
      lastChangedAt: .now
    )
  }
}
