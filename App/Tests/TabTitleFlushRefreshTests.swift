import AppKit
import Clocks
import Foundation
import GhosttyKit
import Testing

@testable import supacode

/// A tab title held back by coalescing must refresh the Active Agents subtitle the
/// same way a title written straight through `updateTitle` does. Those are two
/// separate call sites into `refreshAgentEntriesForTitleChange`, and nothing but a
/// test keeps them from drifting — the withheld title is invisible until the flush
/// lands it, so a flush that forgot to refresh would show a stale subtitle
/// indefinitely rather than for one poll.
@MainActor
struct TabTitleFlushRefreshTests {
  private let start = Date(timeIntervalSince1970: 1_000)

  @Test func flushingAWithheldTitleRefreshesTheAgentEntry() {
    let fixture = makeFixture()
    var received: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { received.append($0) }

    #expect(fixture.state.tabManager.updateTitle(fixture.tabId, title: "⠋ building", now: start))
    received.removeAll()

    // Inside the interval, so the tab bar never sees it and no refresh fires yet.
    #expect(
      fixture.state.tabManager.updateTitle(
        fixture.tabId, title: "⠙ building", now: start.addingTimeInterval(0.2)) == false
    )
    #expect(received.isEmpty, "A withheld title must not reach the entry either")

    let flushed = fixture.state.flushCoalescedTabTitles(now: start.addingTimeInterval(1.5))

    #expect(flushed == [fixture.tabId])
    #expect(received.count == 1, "The flush must refresh the entry, not just the tab")
    #expect(received.last?.paneTitle == "⠙ building")
  }

  /// The flush is called on every detection tick, so the common case — nothing held
  /// back — must not emit. Otherwise the coalescing would trade one source of entry
  /// churn for another.
  @Test func flushingWithNothingWithheldEmitsNothing() {
    let fixture = makeFixture()
    _ = fixture.state.tabManager.updateTitle(fixture.tabId, title: "⠋ building", now: start)
    var received: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { received.append($0) }

    #expect(fixture.state.flushCoalescedTabTitles(now: start.addingTimeInterval(5)).isEmpty)
    #expect(received.isEmpty)
  }

  /// A flush inside the interval must leave the title held, so the one-second spacing
  /// is not quietly bypassed by the poll running more often than that.
  @Test func aFlushInsideTheIntervalHoldsTheTitle() {
    let fixture = makeFixture()
    _ = fixture.state.tabManager.updateTitle(fixture.tabId, title: "⠋ building", now: start)
    _ = fixture.state.tabManager.updateTitle(fixture.tabId, title: "⠙ building", now: start.addingTimeInterval(0.2))
    var received: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { received.append($0) }

    #expect(fixture.state.flushCoalescedTabTitles(now: start.addingTimeInterval(0.5)).isEmpty)
    #expect(received.isEmpty)
    #expect(fixture.state.tabManager.tabs.first?.title == "⠋ building")
  }

  @Test func aWithheldTitleFlushesWithoutAnAgentDetectionTask() async {
    let clock = TestClock()
    let fixture = makeFixture(titleFlushClock: clock)
    var received: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { received.append($0) }

    _ = fixture.state.tabManager.updateTitle(fixture.tabId, title: "A", now: start)
    _ = fixture.state.tabManager.updateTitle(
      fixture.tabId,
      title: "B",
      now: start.addingTimeInterval(0.2)
    )
    #expect(fixture.state.agentDetectionTasks.isEmpty)

    await clock.advance(by: .seconds(1))
    for _ in 0..<10 { await Task.yield() }

    #expect(fixture.state.tabManager.tabs.first?.title == "B")
    #expect(received.map(\.paneTitle) == ["B"])
  }

  private struct Fixture {
    let state: WorktreeTerminalState
    let tabId: TerminalTabID
    let pane: GhosttySurfaceView
  }

  private func makeFixture(
    titleFlushClock: any Clock<Duration> = ContinuousClock()
  ) -> Fixture {
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: Worktree(
        id: "/tmp/repo/worktree",
        name: "worktree",
        detail: "",
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/worktree"),
        repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
      ),
      titleFlushClock: titleFlushClock
    )
    let pane = GhosttySurfaceView(
      runtime: state.runtime,
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/worktree", isDirectory: true),
      fontSize: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    let tabId = state.tabManager.createTab(title: "worktree 1", icon: "terminal")
    state.surfaces[pane.id] = pane
    state.trees[tabId] = SplitTree<GhosttySurfaceView>(view: pane)
    state.focusedSurfaceIdByTab[tabId] = pane.id
    // An entry is only produced for a pane with a detected agent in a known state.
    state.surfaceAgentStates[pane.id] = PaneAgentState(detectedAgent: .claude, state: .working)
    return Fixture(state: state, tabId: tabId, pane: pane)
  }
}
