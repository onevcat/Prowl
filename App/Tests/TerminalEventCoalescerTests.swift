import Foundation
import Testing

@testable import supacode

struct TerminalEventCoalescerTests {
  @Test func dropsConsecutiveIdenticalStateEvents() {
    var coalescer = TerminalEventCoalescer()
    let event = TerminalClient.Event.taskStatusChanged(worktreeID: "w1", status: .running)
    let first = coalescer.shouldEmit(event)
    // A re-emitted identical status is redundant: the slot already holds it.
    let second = coalescer.shouldEmit(event)
    #expect(first)
    #expect(!second)
  }

  @Test func passesDistinctValuesForSameSlot() {
    var coalescer = TerminalEventCoalescer()
    let running = coalescer.shouldEmit(.taskStatusChanged(worktreeID: "w1", status: .running))
    let idle = coalescer.shouldEmit(.taskStatusChanged(worktreeID: "w1", status: .idle))
    // Flipping back is still a real change.
    let runningAgain = coalescer.shouldEmit(.taskStatusChanged(worktreeID: "w1", status: .running))
    #expect(running)
    #expect(idle)
    #expect(runningAgain)
  }

  @Test func keysStateEventsPerWorktree() {
    var coalescer = TerminalEventCoalescer()
    let firstWorktree = coalescer.shouldEmit(.taskStatusChanged(worktreeID: "w1", status: .running))
    // A different worktree has its own slot, so an identical status still passes.
    let secondWorktree = coalescer.shouldEmit(.taskStatusChanged(worktreeID: "w2", status: .running))
    #expect(firstWorktree)
    #expect(secondWorktree)
  }

  @Test func neverCoalescesNotifications() {
    var coalescer = TerminalEventCoalescer()
    let event = TerminalClient.Event.notificationReceived(
      worktreeID: "w1",
      surfaceID: UUID(),
      title: "Build",
      body: "done",
      isViewed: false
    )
    let first = coalescer.shouldEmit(event)
    // Two identical notifications are two distinct user-facing events.
    let second = coalescer.shouldEmit(event)
    #expect(first)
    #expect(second)
  }

  @Test func neverCoalescesLifecycleEvents() {
    var coalescer = TerminalEventCoalescer()
    let tab1 = coalescer.shouldEmit(.tabCreated(worktreeID: "w1"))
    let tab2 = coalescer.shouldEmit(.tabCreated(worktreeID: "w1"))
    let cmd1 = coalescer.shouldEmit(.customCommandSucceeded(worktreeID: "w1", name: "test", durationMs: 5))
    let cmd2 = coalescer.shouldEmit(.customCommandSucceeded(worktreeID: "w1", name: "test", durationMs: 5))
    let id = UUID()
    let removed1 = coalescer.shouldEmit(.agentEntryRemoved(id))
    let removed2 = coalescer.shouldEmit(.agentEntryRemoved(id))
    #expect(tab1)
    #expect(tab2)
    #expect(cmd1)
    #expect(cmd2)
    #expect(removed1)
    #expect(removed2)
  }

  @Test func coalescesFocusRunScriptAndFontSize() {
    var coalescer = TerminalEventCoalescer()
    let surfaceID = UUID()
    let focus1 = coalescer.shouldEmit(.focusChanged(worktreeID: "w1", surfaceID: surfaceID))
    let focus2 = coalescer.shouldEmit(.focusChanged(worktreeID: "w1", surfaceID: surfaceID))
    let run1 = coalescer.shouldEmit(.runScriptStatusChanged(worktreeID: "w1", isRunning: true))
    let run2 = coalescer.shouldEmit(.runScriptStatusChanged(worktreeID: "w1", isRunning: true))
    let font1 = coalescer.shouldEmit(.fontSizeChanged(14))
    let font2 = coalescer.shouldEmit(.fontSizeChanged(14))
    let font3 = coalescer.shouldEmit(.fontSizeChanged(16))
    #expect(focus1)
    #expect(!focus2)
    #expect(run1)
    #expect(!run2)
    #expect(font1)
    #expect(!font2)
    #expect(font3)
  }

  @Test func resetClearsCacheSoAFreshSubscriberIsNotStarved() {
    var coalescer = TerminalEventCoalescer()
    let event = TerminalClient.Event.taskStatusChanged(worktreeID: "w1", status: .running)
    let first = coalescer.shouldEmit(event)
    let second = coalescer.shouldEmit(event)
    // After a resubscribe the cache is cleared, so the current value can be
    // re-delivered to the new stream.
    coalescer.reset()
    let afterReset = coalescer.shouldEmit(event)
    #expect(first)
    #expect(!second)
    #expect(afterReset)
  }

  @Test func forgetDropsKeysForRemovedWorktrees() {
    var coalescer = TerminalEventCoalescer()
    let event = TerminalClient.Event.taskStatusChanged(worktreeID: "w1", status: .running)
    let first = coalescer.shouldEmit(event)
    coalescer.forget(worktreeIDs: ["w1"])
    // The slot is gone, so a returning worktree starts clean.
    let afterForget = coalescer.shouldEmit(event)
    #expect(first)
    #expect(afterForget)
  }
}
