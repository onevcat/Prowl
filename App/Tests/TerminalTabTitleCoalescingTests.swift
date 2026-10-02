import Clocks
import Foundation
import Testing

@testable import supacode

/// `TerminalTabManager.tabs` is observed as a whole, so one tab's title write
/// rebuilds the entire tab bar. Agent TUIs animate a spinner glyph into the
/// title at roughly 10 Hz, so live title writes are spaced out; these tests pin
/// both the spacing and the trailing flush that keeps a settled title from
/// being stranded.
@MainActor
struct TerminalTabTitleCoalescingTests {
  private let start = Date(timeIntervalSince1970: 1_000)

  private func makeManager() -> (TerminalTabManager, TerminalTabID) {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "initial", icon: nil)
    return (manager, id)
  }

  private func title(of manager: TerminalTabManager, _ id: TerminalTabID) -> String? {
    manager.tabs.first(where: { $0.id == id })?.title
  }

  @Test func theFirstTitleAfterAQuietPeriodIsWrittenImmediately() {
    let (manager, id) = makeManager()

    #expect(manager.updateTitle(id, title: "building", now: start))
    #expect(title(of: manager, id) == "building")
  }

  @Test func framesArrivingInsideTheIntervalDoNotReachTheTabs() {
    let (manager, id) = makeManager()
    _ = manager.updateTitle(id, title: "⠋ working", now: start)

    #expect(manager.updateTitle(id, title: "⠙ working", now: start.addingTimeInterval(0.1)) == false)
    #expect(manager.updateTitle(id, title: "⠹ working", now: start.addingTimeInterval(0.2)) == false)

    #expect(
      title(of: manager, id) == "⠋ working",
      "Animation frames must not mutate the observed array"
    )
  }

  @Test func aTitleArrivingAfterTheIntervalIsWrittenAgain() {
    let (manager, id) = makeManager()
    _ = manager.updateTitle(id, title: "⠋ working", now: start)
    _ = manager.updateTitle(id, title: "⠙ working", now: start.addingTimeInterval(0.5))

    #expect(manager.updateTitle(id, title: "⠸ working", now: start.addingTimeInterval(1.1)))
    #expect(title(of: manager, id) == "⠸ working")
  }

  /// Only the newest held-back title survives, so a burst never queues up.
  @Test func flushLandsTheMostRecentSuppressedTitle() {
    let (manager, id) = makeManager()
    _ = manager.updateTitle(id, title: "⠋ working", now: start)
    _ = manager.updateTitle(id, title: "⠙ working", now: start.addingTimeInterval(0.2))
    _ = manager.updateTitle(id, title: "⠸ working", now: start.addingTimeInterval(0.4))

    #expect(manager.flushPendingTitles(now: start.addingTimeInterval(1.5)) == [id])
    #expect(title(of: manager, id) == "⠸ working")
  }

  @Test func flushDoesNothingBeforeTheIntervalElapses() {
    let (manager, id) = makeManager()
    _ = manager.updateTitle(id, title: "⠋ working", now: start)
    _ = manager.updateTitle(id, title: "⠙ working", now: start.addingTimeInterval(0.2))

    #expect(manager.flushPendingTitles(now: start.addingTimeInterval(0.5)).isEmpty)
    #expect(title(of: manager, id) == "⠋ working")
  }

  @Test func flushIsANoOpWhenNothingWasSuppressed() {
    let (manager, id) = makeManager()
    _ = manager.updateTitle(id, title: "done", now: start)

    #expect(manager.flushPendingTitles(now: start.addingTimeInterval(5)).isEmpty)
    #expect(title(of: manager, id) == "done")
  }

  /// A suppressed frame must not resurface after a later title has been written,
  /// or the tab would flick back to a stale animation frame.
  @Test func aSuppressedTitleIsDiscardedOnceANewerOneIsWritten() {
    let (manager, id) = makeManager()
    _ = manager.updateTitle(id, title: "⠋ working", now: start)
    _ = manager.updateTitle(id, title: "⠙ working", now: start.addingTimeInterval(0.2))
    _ = manager.updateTitle(id, title: "finished", now: start.addingTimeInterval(1.1))

    #expect(manager.flushPendingTitles(now: start.addingTimeInterval(9)).isEmpty)
    #expect(title(of: manager, id) == "finished")
  }

  @Test func aSuppressedTitleIsDiscardedWhenTheLatestTitleRevertsToTheVisibleValue() {
    let (manager, id) = makeManager()
    _ = manager.updateTitle(id, title: "A", now: start)
    _ = manager.updateTitle(id, title: "B", now: start.addingTimeInterval(0.2))

    #expect(manager.updateTitle(id, title: "A", now: start.addingTimeInterval(0.4)) == false)
    #expect(manager.flushPendingTitles(now: start.addingTimeInterval(1.5)).isEmpty)
    #expect(title(of: manager, id) == "A")
  }

  @Test func coalescingIsPerTabNotGlobal() {
    let manager = TerminalTabManager()
    let first = manager.createTab(title: "first", icon: nil)
    let second = manager.createTab(title: "second", icon: nil)

    #expect(manager.updateTitle(first, title: "⠋ one", now: start))
    // The second tab has its own history, so its first write is not held back.
    #expect(manager.updateTitle(second, title: "⠋ two", now: start.addingTimeInterval(0.1)))

    #expect(title(of: manager, first) == "⠋ one")
    #expect(title(of: manager, second) == "⠋ two")
  }

  @Test func automaticFlushRearmsForTheNextTabsLaterDeadline() async {
    let clock = TestClock()
    let manager = TerminalTabManager(titleFlushClock: clock)
    let first = manager.createTab(title: "first", icon: nil)
    let second = manager.createTab(title: "second", icon: nil)
    var flushed: [[TerminalTabID]] = []
    manager.onCoalescedTitlesFlushed = { flushed.append($0) }

    _ = manager.updateTitle(first, title: "first A", now: start)
    _ = manager.updateTitle(first, title: "first B", now: start.addingTimeInterval(0.1))
    _ = manager.updateTitle(second, title: "second A", now: start.addingTimeInterval(0.4))
    _ = manager.updateTitle(second, title: "second B", now: start.addingTimeInterval(0.5))

    await clock.advance(by: .seconds(0.9))
    for _ in 0..<10 { await Task.yield() }

    #expect(title(of: manager, first) == "first B")
    #expect(title(of: manager, second) == "second A")
    #expect(flushed == [[first]])

    await clock.advance(by: .seconds(0.4))
    for _ in 0..<10 { await Task.yield() }

    #expect(title(of: manager, second) == "second B")
    #expect(flushed == [[first], [second]])
  }

  @Test func aLockedTitleIsNeverWrittenOrHeld() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "pinned", icon: nil, isTitleLocked: true)

    #expect(manager.updateTitle(id, title: "⠋ working", now: start) == false)
    #expect(manager.updateTitle(id, title: "⠙ working", now: start.addingTimeInterval(0.2)) == false)
    #expect(manager.flushPendingTitles(now: start.addingTimeInterval(5)).isEmpty)
    #expect(title(of: manager, id) == "pinned")
  }

  /// A custom title masks the live one, so the visible title never moves — the
  /// live value still updates underneath so clearing the custom title reveals it.
  @Test func aCustomTitleMasksTheFlushedLiveTitle() {
    let (manager, id) = makeManager()
    _ = manager.setCustomTitle(id, title: "my tab")
    _ = manager.updateTitle(id, title: "⠋ working", now: start)
    _ = manager.updateTitle(id, title: "⠙ working", now: start.addingTimeInterval(0.2))

    #expect(manager.flushPendingTitles(now: start.addingTimeInterval(1.5)).isEmpty)
    #expect(title(of: manager, id) == "⠙ working")
    #expect(manager.tabs.first(where: { $0.id == id })?.displayTitle == "my tab")
  }

  /// Asserts the bookkeeping itself, not `flushPendingTitles`'s return value: that
  /// value is empty for a closed tab whether or not the prune ran, because the flush
  /// skips any id missing from `tabs`. Reading the retained ids is the only way to
  /// tell a working prune from a leak that grows with every tab ever closed.
  @Test func closingATabDropsItsCoalescingState() {
    let (manager, id) = makeManager()
    _ = manager.updateTitle(id, title: "⠋ working", now: start)
    _ = manager.updateTitle(id, title: "⠙ working", now: start.addingTimeInterval(0.2))
    #expect(manager.coalescedTabIDsForTesting == [id], "Both a last-write stamp and a pending title are held")

    manager.closeTab(id)

    #expect(manager.coalescedTabIDsForTesting.isEmpty, "Closing the tab must drop its bookkeeping, not leak it")
    #expect(manager.flushPendingTitles(now: start.addingTimeInterval(5)).isEmpty)
    #expect(manager.tabs.isEmpty)
  }

  /// A surviving tab must keep its state when a sibling closes, so the prune cannot
  /// be "fixed" by clearing everything.
  @Test func closingOneTabKeepsAnotherTabsCoalescingState() {
    let (manager, kept) = makeManager()
    let closed = manager.createTab(title: "second", icon: nil)
    _ = manager.updateTitle(kept, title: "⠋ kept", now: start)
    _ = manager.updateTitle(closed, title: "⠋ closed", now: start)

    manager.closeTab(closed)

    #expect(manager.coalescedTabIDsForTesting == [kept])
  }

  /// Pins the comparison at `TerminalTabManager.swift`'s `<` against the interval.
  /// Without a case landing exactly on the boundary, changing it to `<=` — which
  /// would withhold a title that has waited the full interval — passes every other
  /// test in this file.
  @Test func aTitleArrivingExactlyOnTheIntervalIsWritten() {
    let (manager, id) = makeManager()
    _ = manager.updateTitle(id, title: "⠋ working", now: start)
    let boundary = start.addingTimeInterval(TerminalTabManager.liveTitleCoalescingInterval)

    #expect(manager.updateTitle(id, title: "⠙ working", now: boundary))
    #expect(title(of: manager, id) == "⠙ working")
  }

  /// The other side of the same boundary: one instant earlier must still be withheld.
  @Test func aTitleArrivingJustInsideTheIntervalIsWithheld() {
    let (manager, id) = makeManager()
    _ = manager.updateTitle(id, title: "⠋ working", now: start)
    let justInside = start.addingTimeInterval(TerminalTabManager.liveTitleCoalescingInterval - 0.001)

    #expect(manager.updateTitle(id, title: "⠙ working", now: justInside) == false)
    #expect(title(of: manager, id) == "⠋ working")
  }
}
