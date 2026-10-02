import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import supacode

/// Agent TUIs animate a spinner glyph inside the terminal title (`⠦ spx-h` →
/// `⠧ spx-h`) at roughly 10 Hz. Each frame reaches `emitAgentEntry` as a new
/// `ActiveAgentEntry`, and forwarding all of them mutates the Active Agents
/// state — and dirties the SwiftUI graph — for a change no one perceives.
/// `emitAgentEntry` must space title-only emissions out while still forwarding
/// real state changes immediately.
@MainActor
struct AgentEntryTitleCoalescingTests {
  private let start = Date(timeIntervalSince1970: 1_000)

  @Test func spinnerFramesWithinTheIntervalAreCoalesced() {
    let fixture = makeFixture()
    var received: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { received.append($0) }
    let working = PaneAgentState(detectedAgent: .claude, state: .working)

    fixture.emit(working, at: start)
    // Four spinner frames over 400 ms, as a real agent would produce.
    for frame in ["⠦ spx-h", "⠧ spx-h", "⠇ spx-h", "⠏ spx-h"].enumerated() {
      fixture.setTitle(frame.element)
      fixture.emit(working, at: start.addingTimeInterval(0.1 * Double(frame.offset + 1)))
    }

    #expect(received.count == 1, "Only the initial emission should reach the consumer")
  }

  @Test func aTitleChangeEmitsOnceTheIntervalElapses() {
    let fixture = makeFixture()
    var received: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { received.append($0) }
    let working = PaneAgentState(detectedAgent: .claude, state: .working)

    fixture.emit(working, at: start)
    fixture.setTitle("⠦ spx-h")
    fixture.emit(working, at: start.addingTimeInterval(0.5))
    // Past the interval, so the newest title is forwarded.
    fixture.setTitle("⠧ spx-h")
    fixture.emit(working, at: start.addingTimeInterval(1.5))

    #expect(received.count == 2)
    // The suppressed frame is never recorded, so the emission that follows
    // carries the title as of that moment rather than the stale frame.
    #expect(received.last?.paneTitle == "⠧ spx-h")
  }

  @Test func aVisibleStateChangeEmitsImmediatelyDespiteTheInterval() {
    let fixture = makeFixture()
    var received: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { received.append($0) }

    fixture.emit(PaneAgentState(detectedAgent: .claude, state: .working), at: start)
    // Well inside the coalescing window, but `displayState` is user-visible and
    // must never be delayed.
    fixture.setTitle("⠧ spx-h")
    fixture.emit(PaneAgentState(detectedAgent: .claude, state: .blocked), at: start.addingTimeInterval(0.05))

    #expect(received.map(\.displayState) == [.working, .blocked])
    #expect(received.last?.paneTitle == "⠧ spx-h", "The pending title rides along on the real change")
  }

  @Test func identicalTitlesNeverEmitEvenAfterTheInterval() {
    let fixture = makeFixture()
    var received: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { received.append($0) }
    let working = PaneAgentState(detectedAgent: .claude, state: .working)

    fixture.emit(working, at: start)
    fixture.emit(working, at: start.addingTimeInterval(5))
    fixture.emit(working, at: start.addingTimeInterval(10))

    #expect(received.count == 1, "Coalescing must not turn into a periodic re-emit")
  }

  @Test func returningToTheVisibleTitleDiscardsThePendingFrame() {
    let fixture = makeFixture()
    var received: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { received.append($0) }
    let working = PaneAgentState(detectedAgent: .claude, state: .working)

    fixture.setTitle("A")
    fixture.emit(working, at: start)
    fixture.setTitle("B")
    fixture.emit(working, at: start.addingTimeInterval(0.2))

    // The title returns to what the consumer already displays before the interval ends. The
    // withheld B is now obsolete and must not flash back onto the row during the trailing flush.
    fixture.setTitle("A")
    fixture.emit(working, at: start.addingTimeInterval(0.4))
    fixture.flush(at: start.addingTimeInterval(1.2))

    #expect(received.count == 1)
    #expect(received.last?.paneTitle == "A")
  }

  @Test func aSettledTitleIsFlushedByTheNextPoll() {
    let fixture = makeFixture()
    var received: [ActiveAgentEntry] = []
    fixture.state.onAgentEntryChanged = { received.append($0) }
    let working = PaneAgentState(detectedAgent: .claude, state: .working)

    fixture.emit(working, at: start)
    // The spinner's final frame is suppressed, then the agent stops animating,
    // so no further title change will ever arrive to carry it.
    fixture.setTitle("spx-h")
    fixture.emit(working, at: start.addingTimeInterval(0.2))
    #expect(received.count == 1)

    // A poll inside the window must not release it early.
    fixture.flush(at: start.addingTimeInterval(0.5))
    #expect(received.count == 1)

    fixture.flush(at: start.addingTimeInterval(1.2))
    #expect(received.count == 2)
    #expect(received.last?.paneTitle == "spx-h")

    // Nothing is left pending, so later polls stay quiet.
    fixture.flush(at: start.addingTimeInterval(5))
    #expect(received.count == 2)
  }

  @Test func comparisonIgnoresOnlyRawStateAndPaneTitle() {
    let base = makeEntry(paneTitle: "⠦ spx-h", rawState: .working, displayState: .working)
    let spinnerMoved = makeEntry(paneTitle: "⠧ spx-h", rawState: .idle, displayState: .working)
    let stateMoved = makeEntry(paneTitle: "⠦ spx-h", rawState: .working, displayState: .blocked)

    #expect(base.equalsIgnoringRawStateAndPaneTitle(spinnerMoved))
    #expect(!base.equalsIgnoringRawStateAndPaneTitle(stateMoved))
    // The narrower comparison still treats a title move as a difference.
    #expect(!base.equalsIgnoringRawState(spinnerMoved))
  }

  /// The test above pins one field this comparison must still notice. It
  /// normalizes two, and nothing structural stops a later edit from normalizing
  /// a third — the failure would be silent: it compiles, every test in this file
  /// still passes, and the only symptom is a real change that never reaches the
  /// sidebar. Walk the remaining fields so widening the normalization fails here
  /// instead of in the UI.
  @Test func everyOtherFieldStillBreaksTheTitleComparison() {
    let base = makeEntry()
    let variants: [(field: String, entry: ActiveAgentEntry)] = [
      ("id", makeEntry(id: Self.otherEntryID)),
      ("worktreeID", makeEntry(worktreeID: "/tmp/repo/other")),
      ("worktreeName", makeEntry(worktreeName: "other")),
      // Resolves the repository and branch the row displays, so a suppressed
      // change leaves the sidebar naming the directory the agent has left.
      ("workingDirectory", makeEntry(workingDirectory: URL(fileURLWithPath: "/tmp/repo/other"))),
      ("workingDirectory=nil", makeEntry(workingDirectory: nil)),
      ("tabID", makeEntry(tabID: Self.otherEntryTabID)),
      ("surfaceID", makeEntry(surfaceID: Self.otherEntryID)),
      ("paneIndex", makeEntry(paneIndex: 2)),
      ("iconLookupToken", makeEntry(iconLookupToken: "codex")),
      ("agent", makeEntry(agent: .codex)),
      ("launchProfileName", makeEntry(launchProfileName: "Review Profile")),
      // Carries the resume target `prowl agents` reports; a suppressed change
      // would keep pointing at the previous session's transcript.
      ("session", makeEntry(session: Self.otherSession)),
      ("session=nil", makeEntry(session: nil)),
      ("displayState", makeEntry(displayState: .blocked)),
      ("lastChangedAt", makeEntry(lastChangedAt: Date(timeIntervalSince1970: 5_000))),
    ]

    for variant in variants {
      #expect(
        !base.equalsIgnoringRawStateAndPaneTitle(variant.entry),
        "A change to \(variant.field) must still emit; normalizing it would hide the change from the sidebar"
      )
    }

    // The two fields the comparison exists to ignore, moving together.
    #expect(base.equalsIgnoringRawStateAndPaneTitle(makeEntry(paneTitle: "⠧ spx-h", rawState: .idle)))
  }

  /// Defaults spell out every field so a case can override exactly one and the
  /// assertion stays about that field alone.
  private func makeEntry(
    id: UUID = entryID,
    worktreeID: Worktree.ID = "/tmp/repo/worktree",
    worktreeName: String = "worktree",
    workingDirectory: URL? = URL(fileURLWithPath: "/tmp/repo/worktree"),
    tabID: TerminalTabID = entryTabID,
    paneTitle: String = "⠦ spx-h",
    surfaceID: UUID = entryID,
    paneIndex: Int = 1,
    iconLookupToken: String = "claude",
    agent: DetectedAgent = .claude,
    session: AgentSession? = baseSession,
    rawState: AgentRawState = .working,
    displayState: AgentDisplayState = .working,
    lastChangedAt: Date = Date(timeIntervalSince1970: 0),
    launchProfileName: String? = nil
  ) -> ActiveAgentEntry {
    ActiveAgentEntry(
      id: id,
      worktreeID: worktreeID,
      worktreeName: worktreeName,
      workingDirectory: workingDirectory,
      tabID: tabID,
      paneTitle: paneTitle,
      surfaceID: surfaceID,
      paneIndex: paneIndex,
      iconLookupToken: iconLookupToken,
      agent: agent,
      session: session,
      rawState: rawState,
      displayState: displayState,
      lastChangedAt: lastChangedAt,
      launchProfileName: launchProfileName
    )
  }

  private static let entryID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
  private static let otherEntryID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FE")!
  /// Shared so two entries under comparison differ only in the field under test.
  private static let entryTabID = TerminalTabID()
  private static let otherEntryTabID = TerminalTabID()
  private static let baseSession = AgentSession(
    id: "session-1",
    transcriptPath: URL(fileURLWithPath: "/tmp/transcripts/session-1.jsonl"),
    source: .openFile,
    confidence: .exact
  )
  private static let otherSession = AgentSession(
    id: "session-2",
    transcriptPath: URL(fileURLWithPath: "/tmp/transcripts/session-2.jsonl"),
    source: .openFile,
    confidence: .exact
  )

  /// `TerminalTabManager` spaces out its own live title writes on a separate
  /// clock. These tests exercise the entry-level coalescing, so each title is
  /// stamped far enough apart that the tab layer never withholds one and the
  /// two mechanisms stay independently testable.
  private final class TitleClock {
    private var now = Date(timeIntervalSince1970: 0)

    func next() -> Date {
      now = now.addingTimeInterval(TerminalTabManager.liveTitleCoalescingInterval * 2)
      return now
    }
  }

  private struct Fixture {
    let state: WorktreeTerminalState
    let tabId: TerminalTabID
    let pane: GhosttySurfaceView
    let titleClock = TitleClock()

    func setTitle(_ title: String) {
      state.tabManager.updateTitle(tabId, title: title, now: titleClock.next())
    }

    func emit(_ paneState: PaneAgentState, at now: Date) {
      state.emitAgentEntry(surfaceID: pane.id, tabId: tabId, state: paneState, now: now)
    }

    /// Stands in for one turn of the detection poll, which drives the flush.
    func flush(at now: Date) {
      state.flushPendingAgentEntry(surfaceID: pane.id, now: now)
    }
  }

  private func makeFixture() -> Fixture {
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
    return Fixture(state: state, tabId: tabId, pane: pane)
  }
}
