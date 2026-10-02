import Clocks
import Foundation
import GhosttyKit
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct TerminalCloseUndoStackTests {
  @Test func popsInCloseOrderAndCancelsExpiry() async {
    let clock = TestClock()
    let stack = TerminalCloseUndoStack(timeout: .seconds(5), clock: clock)
    var expired: [UUID] = []
    stack.onExpire = { expired.append(contentsOf: $0.map(\.id)) }
    let first = makeView()
    let second = makeView()

    stack.recordClose(makeTabRecord(first))
    stack.recordClose(makeTabRecord(second))

    #expect(stack.canUndo)
    #expect(stack.popUndo()?.retainedSurfaces.first === second)
    #expect(stack.popUndo()?.retainedSurfaces.first === first)
    #expect(!stack.canUndo)

    await clock.advance(by: .seconds(6))
    await Task.yield()
    #expect(expired.isEmpty)
  }

  @Test func eachEntryExpiresOnItsOwnTimer() async {
    let clock = TestClock()
    let stack = TerminalCloseUndoStack(timeout: .seconds(5), clock: clock)
    var expired: [UUID] = []
    stack.onExpire = { expired.append(contentsOf: $0.map(\.id)) }
    let first = makeView()
    let second = makeView()

    stack.recordClose(makeTabRecord(first))
    await clock.advance(by: .seconds(3))
    stack.recordClose(makeTabRecord(second))
    await clock.advance(by: .seconds(2))
    await settle()

    #expect(expired == [first.id])
    #expect(stack.canUndo)

    await clock.advance(by: .seconds(3))
    await settle()

    #expect(expired == [first.id, second.id])
    #expect(!stack.canUndo)
  }

  @Test func zeroTimeoutExpiresAtOnce() {
    let stack = TerminalCloseUndoStack(timeout: .zero, clock: TestClock())
    var expired: [UUID] = []
    stack.onExpire = { expired.append(contentsOf: $0.map(\.id)) }
    let view = makeView()

    stack.recordClose(makeTabRecord(view))

    #expect(!stack.isEnabled)
    #expect(!stack.canUndo)
    #expect(expired == [view.id])
  }

  @Test func newCloseClearsRedoUnlessRedoing() {
    let stack = TerminalCloseUndoStack(timeout: .seconds(5), clock: TestClock())
    stack.recordReopen(.tabs(worktreeID: "wt", [TerminalTabID()]))
    #expect(stack.canRedo)

    stack.recordClose(makeTabRecord(makeView()), clearingRedo: false)
    #expect(stack.canRedo)

    stack.recordClose(makeTabRecord(makeView()))
    #expect(!stack.canRedo)
  }

  @Test func discardingAnExitedSurfaceKeepsTheRestOfTheRecord() {
    let stack = TerminalCloseUndoStack(timeout: .seconds(5), clock: TestClock())
    var expired: [UUID] = []
    stack.onExpire = { expired.append(contentsOf: $0.map(\.id)) }
    let left = makeView()
    let right = makeView()
    let tree = try? SplitTree(view: left).inserting(view: right, at: left, direction: .right)
    let record = TerminalClosedTabRecord(
      item: TerminalTabItem(title: "tab", icon: nil),
      index: 0,
      wasSelected: true,
      tree: tree ?? SplitTree(view: left),
      focusedSurfaceID: right.id,
      wasRunScriptTab: false,
      boundDirectoryKey: nil,
      contexts: [:]
    )
    stack.recordClose(.tabs(worktreeID: "wt", [record]))

    stack.discardSurface(id: right.id)

    #expect(expired == [right.id])
    let remaining = stack.popUndo()
    #expect(remaining?.retainedSurfaces.map(\.id) == [left.id])
    if case .tabs(_, let tabs) = remaining {
      #expect(tabs.first?.focusedSurfaceID == nil)
    } else {
      Issue.record("expected a tab record")
    }
  }

  @Test func discardingTheOnlySurfaceDropsTheRecord() {
    let stack = TerminalCloseUndoStack(timeout: .seconds(5), clock: TestClock())
    var expired: [UUID] = []
    stack.onExpire = { expired.append(contentsOf: $0.map(\.id)) }
    let view = makeView()
    stack.recordClose(
      .pane(
        worktreeID: "wt",
        TerminalClosedPaneRecord(
          tabID: TerminalTabID(), view: view, previousTree: SplitTree(view: view), wasFocused: true,
          context: TerminalRetainedSurfaceContext(launchProfile: nil, hookRegistration: nil))))

    stack.discardSurface(id: view.id)

    #expect(expired == [view.id])
    #expect(!stack.canUndo)
  }

  @Test func discardByWorktreeFreesOnlyThatWorktree() {
    let stack = TerminalCloseUndoStack(timeout: .seconds(5), clock: TestClock())
    var expired: [UUID] = []
    stack.onExpire = { expired.append(contentsOf: $0.map(\.id)) }
    let kept = makeView()
    let dropped = makeView()
    stack.recordClose(makeTabRecord(kept, worktreeID: "keep"))
    stack.recordClose(makeTabRecord(dropped, worktreeID: "drop"))
    stack.recordReopen(.tabs(worktreeID: "drop", [TerminalTabID()]))

    stack.discard { $0 == "drop" }

    #expect(expired == [dropped.id])
    #expect(!stack.canRedo)
    #expect(stack.popUndo()?.retainedSurfaces.first === kept)
  }

  private func makeView() -> GhosttySurfaceView {
    GhosttySurfaceView(
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
  }

  private func makeTabRecord(_ view: GhosttySurfaceView, worktreeID: Worktree.ID = "wt") -> TerminalCloseRecord {
    .tabs(
      worktreeID: worktreeID,
      [
        TerminalClosedTabRecord(
          item: TerminalTabItem(title: "tab", icon: nil),
          index: 0,
          wasSelected: true,
          tree: SplitTree(view: view),
          focusedSurfaceID: view.id,
          wasRunScriptTab: false,
          boundDirectoryKey: nil,
          contexts: [:]
        )
      ])
  }

  private func settle() async {
    for _ in 0..<10 {
      await Task.yield()
    }
  }
}
