import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import supacode

@MainActor
struct ActiveAgentEntryPaneTitleTests {
  @Test func entryUsesItsOwnSurfaceTitle() throws {
    let fixture = try makeSplitFixture()
    fixture.focusedPane.bridge.state.title = "title 1"
    fixture.unfocusedPane.bridge.state.title = "title 2"
    // Mirrors onTitleChange: only the focused pane's title reaches the tab.
    fixture.state.tabManager.updateTitle(fixture.tabId, title: "title 1")

    let focusedEntry = try #require(
      fixture.state.activeAgentEntry(
        surfaceID: fixture.focusedPane.id,
        tabId: fixture.tabId,
        state: PaneAgentState(detectedAgent: .claude, state: .working)
      )
    )
    let unfocusedEntry = try #require(
      fixture.state.activeAgentEntry(
        surfaceID: fixture.unfocusedPane.id,
        tabId: fixture.tabId,
        state: PaneAgentState(detectedAgent: .claude, state: .working)
      )
    )

    #expect(focusedEntry.paneTitle == "title 1")
    #expect(unfocusedEntry.paneTitle == "title 2")
  }

  @Test func entryFallsBackToTabDisplayTitleWithoutSurfaceTitle() throws {
    let fixture = try makeSplitFixture()
    fixture.state.tabManager.updateTitle(fixture.tabId, title: "tab title")

    let entry = try #require(
      fixture.state.activeAgentEntry(
        surfaceID: fixture.unfocusedPane.id,
        tabId: fixture.tabId,
        state: PaneAgentState(detectedAgent: .claude, state: .working)
      )
    )

    #expect(entry.paneTitle == "tab title")
  }

  @Test func unfocusedPaneTitleChangeReemitsItsEntry() throws {
    let fixture = try makeSplitFixture()
    fixture.state.surfaceAgentStates[fixture.unfocusedPane.id] = PaneAgentState(
      detectedAgent: .claude,
      state: .working
    )
    fixture.state.configureBridgeCallbacks(for: fixture.unfocusedPane, tabId: fixture.tabId)
    var received: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { received.append($0) }

    // The bridge writes state.title before invoking onTitleChange.
    fixture.unfocusedPane.bridge.state.title = "title 2"
    fixture.unfocusedPane.bridge.onTitleChange?("title 2")

    #expect(received.map(\.paneTitle) == ["title 2"])
  }

  @Test func focusedPaneTitleChangeRefreshesAllEntriesInTab() throws {
    let fixture = try makeSplitFixture()
    fixture.state.surfaceAgentStates[fixture.focusedPane.id] = PaneAgentState(
      detectedAgent: .claude,
      state: .working
    )
    fixture.state.surfaceAgentStates[fixture.unfocusedPane.id] = PaneAgentState(
      detectedAgent: .claude,
      state: .working
    )
    fixture.unfocusedPane.bridge.state.title = "title 2"
    fixture.state.configureBridgeCallbacks(for: fixture.focusedPane, tabId: fixture.tabId)
    var received: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { received.append($0) }

    fixture.focusedPane.bridge.state.title = "title 1"
    fixture.focusedPane.bridge.onTitleChange?("title 1")

    // Both panes re-emit (the tab's fallback title changed), each keeping its own title.
    #expect(received.count == 2)
    #expect(Set(received.map(\.paneTitle)) == ["title 1", "title 2"])
  }

  private struct Fixture {
    let state: WorktreeTerminalState
    let tabId: TerminalTabID
    let focusedPane: GhosttySurfaceView
    let unfocusedPane: GhosttySurfaceView
  }

  private func makeSplitFixture() throws -> Fixture {
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: Worktree(
        id: "/tmp/repo/worktree",
        name: "worktree",
        detail: "",
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/worktree"),
        repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
      )
    )
    let focusedPane = makeSurface(state: state)
    let unfocusedPane = makeSurface(state: state)
    let tabId = state.tabManager.createTab(title: "worktree 1", icon: "terminal")
    state.surfaces[focusedPane.id] = focusedPane
    state.surfaces[unfocusedPane.id] = unfocusedPane
    state.trees[tabId] = try SplitTree<GhosttySurfaceView>(view: focusedPane)
      .inserting(view: unfocusedPane, at: focusedPane, direction: .right)
    state.focusedSurfaceIdByTab[tabId] = focusedPane.id
    return Fixture(
      state: state,
      tabId: tabId,
      focusedPane: focusedPane,
      unfocusedPane: unfocusedPane
    )
  }

  private func makeSurface(state: WorktreeTerminalState) -> GhosttySurfaceView {
    GhosttySurfaceView(
      runtime: state.runtime,
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/worktree", isDirectory: true),
      fontSize: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
  }
}
