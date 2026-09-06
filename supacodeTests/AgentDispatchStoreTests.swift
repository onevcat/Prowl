import Clocks
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct AgentDispatchStoreTests {
  @Test func issuanceBindingAndImmutableTargetSurviveCompletion() throws {
    let store = makeStore(ids: ["d1"])
    let issued = try store.issue()
    #expect(issued.record == .pending(id: "d1", createdAt: Self.start))
    #expect(issued.binding == nil)

    let binding = binding(surfaceID: UUID())
    try store.bind(dispatchID: "d1", binding: binding)
    let result = try store.complete(
      dispatchID: "d1",
      outcome: .succeeded,
      summary: "Implemented and verified.",
      callerSurfaceID: binding.surfaceID
    )

    #expect(!result.replayed)
    #expect(result.snapshot.binding == binding)
    #expect(
      result.snapshot.record
        == .completed(
          id: "d1",
          outcome: .succeeded,
          summary: "Implemented and verified.",
          createdAt: Self.start,
          completedAt: Self.start
        )
    )
  }

  @Test func completionIsIdempotentForIdenticalContentAndRejectsConflictsAndWrongPane() throws {
    let store = makeStore(ids: ["d1"])
    _ = try store.issue()
    let binding = binding(surfaceID: UUID())
    try store.bind(dispatchID: "d1", binding: binding)

    _ = try store.complete(
      dispatchID: "d1", outcome: .failed, summary: "SDK unavailable", callerSurfaceID: binding.surfaceID)
    let replay = try store.complete(
      dispatchID: "d1", outcome: .failed, summary: "SDK unavailable", callerSurfaceID: binding.surfaceID)
    #expect(replay.replayed)
    #expect(throws: AgentDispatchStoreError.alreadyCompleted) {
      try store.complete(
        dispatchID: "d1", outcome: .succeeded, summary: "Different", callerSurfaceID: binding.surfaceID)
    }

    let second = makeStore(ids: ["d2"])
    _ = try second.issue()
    try second.bind(dispatchID: "d2", binding: binding)
    #expect(throws: AgentDispatchStoreError.sourceMismatch) {
      try second.complete(
        dispatchID: "d2", outcome: .succeeded, summary: "Done", callerSurfaceID: UUID())
    }
  }

  @Test func multipleWaitersReceiveIndependentTerminalSnapshots() async throws {
    let store = makeStore(ids: ["d1"])
    _ = try store.issue()
    let binding = binding(surfaceID: UUID())
    try store.bind(dispatchID: "d1", binding: binding)
    var first = try store.observe(dispatchID: "d1").makeAsyncIterator()
    var second = try store.observe(dispatchID: "d1").makeAsyncIterator()
    #expect(store.subscriberCount(dispatchID: "d1") == 2)
    let pending = try #require(store.snapshot(dispatchID: "d1"))
    #expect(await first.next() == .snapshot(pending))
    #expect(await second.next() == .snapshot(pending))

    let completed = try store.complete(
      dispatchID: "d1", outcome: .succeeded, summary: "Done", callerSurfaceID: binding.surfaceID)

    #expect(await first.next() == .changed(completed.snapshot))
    #expect(await second.next() == .changed(completed.snapshot))
    #expect(await first.next() == nil)
    #expect(await second.next() == nil)
    #expect(store.subscriberCount(dispatchID: "d1") == 0)
  }

  @Test func capacityEvictsOldestTerminalButNeverPending() throws {
    let store = makeStore(capacity: 2, ids: ["d1", "d2", "d3", "d4"])
    _ = try store.issue()
    let firstBinding = binding(surfaceID: UUID())
    try store.bind(dispatchID: "d1", binding: firstBinding)
    _ = try store.complete(
      dispatchID: "d1", outcome: .succeeded, summary: "Done", callerSurfaceID: firstBinding.surfaceID)
    _ = try store.issue()

    _ = try store.issue()
    #expect(store.snapshot(dispatchID: "d1") == nil)
    #expect(store.snapshot(dispatchID: "d2") != nil)
    #expect(store.snapshot(dispatchID: "d3") != nil)

    #expect(throws: AgentDispatchStoreError.capacityExceeded) {
      try store.issue()
    }
  }

  @Test func abandonmentIsIdempotentAndRecoversAllPendingCapacity() throws {
    let store = makeStore(capacity: 2, ids: ["d1", "d2", "d3"])
    let first = try store.issue()
    _ = try store.issue()
    #expect(throws: AgentDispatchStoreError.capacityExceeded) { try store.issue() }

    let abandoned = try store.abandon(dispatchID: first.record.id, reason: "Worker returned to shell")
    #expect(!abandoned.replayed)
    #expect(
      abandoned.snapshot.record
        == .abandoned(
          id: "d1",
          createdAt: Self.start,
          abandonedAt: Self.start,
          reason: "Worker returned to shell"
        )
    )
    #expect(try store.abandon(dispatchID: "d1", reason: "Worker returned to shell").replayed)
    #expect(throws: AgentDispatchStoreError.alreadyTerminal) {
      try store.abandon(dispatchID: "d1", reason: "Different")
    }

    _ = try store.issue()
    #expect(store.snapshot(dispatchID: "d1") == nil)
    #expect(store.snapshot(dispatchID: "d3") != nil)
  }

  @Test func firstSerializedTerminalMutationWinsCompletionAbandonmentRace() throws {
    let completionFirst = try makeBoundStore(id: "d1")
    _ = try completionFirst.store.complete(
      dispatchID: "d1",
      outcome: .succeeded,
      summary: "Done",
      callerSurfaceID: completionFirst.binding.surfaceID
    )
    #expect(throws: AgentDispatchStoreError.alreadyTerminal) {
      try completionFirst.store.abandon(dispatchID: "d1", reason: "Too late")
    }

    let abandonFirst = try makeBoundStore(id: "d2")
    _ = try abandonFirst.store.abandon(dispatchID: "d2", reason: "Stop waiting")
    #expect(throws: AgentDispatchStoreError.alreadyTerminal) {
      try abandonFirst.store.complete(
        dispatchID: "d2",
        outcome: .succeeded,
        summary: "Too late",
        callerSurfaceID: abandonFirst.binding.surfaceID
      )
    }
  }

  @Test func surfaceCloseAllowsCompletionInsideWindowAndCommitsGoneAfterBoundary() async throws {
    let clock = TestClock()
    let completionFirst = try makeBoundStore(id: "d1", clock: clock)
    completionFirst.store.surfaceClosed(surfaceID: completionFirst.binding.surfaceID)
    await registerCoalescingTask()
    await clock.advance(by: .milliseconds(299))
    let completed = try completionFirst.store.complete(
      dispatchID: "d1",
      outcome: .succeeded,
      summary: "Done",
      callerSurfaceID: completionFirst.binding.surfaceID
    )
    await clock.advance(by: .milliseconds(1))
    #expect(completionFirst.store.snapshot(dispatchID: "d1") == completed.snapshot)

    let secondClock = TestClock()
    let goneFirst = try makeBoundStore(id: "d2", clock: secondClock)
    goneFirst.store.surfaceClosed(surfaceID: goneFirst.binding.surfaceID)
    await registerCoalescingTask()
    await secondClock.advance(by: .milliseconds(300))
    for _ in 0..<10 { await Task.yield() }
    #expect(
      goneFirst.store.snapshot(dispatchID: "d2")?.record
        == .gone(
          id: "d2",
          createdAt: Self.start,
          goneAt: Self.start,
          reason: .surfaceClosed
        )
    )
    #expect(throws: AgentDispatchStoreError.alreadyTerminal) {
      try goneFirst.store.complete(
        dispatchID: "d2", outcome: .succeeded, summary: "Late", callerSurfaceID: goneFirst.binding.surfaceID)
    }
  }

  @Test func turnEndedCoalescesThenNotifiesIncompleteWithoutTerminalizing() async throws {
    let clock = TestClock()
    let fixture = try makeBoundStore(id: "d1", clock: clock)
    var waiter = try fixture.store.observe(dispatchID: "d1").makeAsyncIterator()
    _ = await waiter.next()

    fixture.store.noteTerminalEvidence(dispatchID: "d1", evidence: .turnEnded)
    await registerCoalescingTask()
    await clock.advance(by: .milliseconds(300))
    let pending = try #require(fixture.store.snapshot(dispatchID: "d1"))
    #expect(await waiter.next() == .incomplete(pending))
    #expect(fixture.store.snapshot(dispatchID: "d1")?.record.state == .pending)
  }

  @Test func lateWaitersReceiveActiveEvidenceAndLaterActivityInvalidatesIt() async throws {
    let clock = TestClock()
    let fixture = try makeBoundStore(id: "d1", clock: clock)
    fixture.store.noteTerminalEvidence(dispatchID: "d1", evidence: .turnEnded)
    await registerCoalescingTask()
    await clock.advance(by: .milliseconds(300))
    for _ in 0..<10 { await Task.yield() }

    var late = try fixture.store.observe(dispatchID: "d1").makeAsyncIterator()
    let pending = try #require(fixture.store.snapshot(dispatchID: "d1"))
    #expect(await late.next() == .incomplete(pending))

    fixture.store.noteActivity(
      surfaceID: fixture.binding.surfaceID,
      evidenceEpoch: fixture.binding.evidenceEpoch
    )
    var afterActivity = try fixture.store.observe(dispatchID: "d1").makeAsyncIterator()
    _ = await afterActivity.next()
    let completed = try fixture.store.complete(
      dispatchID: "d1",
      outcome: .succeeded,
      summary: "Done after more activity",
      callerSurfaceID: fixture.binding.surfaceID
    )
    #expect(await afterActivity.next() == .changed(completed.snapshot))

    let needsInput = try makeBoundStore(id: "d2")
    needsInput.store.noteTerminalEvidence(dispatchID: "d2", evidence: .needsInput)
    var attentionWaiter = try needsInput.store.observe(dispatchID: "d2").makeAsyncIterator()
    let attentionPending = try #require(needsInput.store.snapshot(dispatchID: "d2"))
    #expect(await attentionWaiter.next() == .needsInput(attentionPending))
  }

  @Test func surfaceEvidenceMustMatchBoundEpoch() async throws {
    let fixture = try makeBoundStore(id: "d1")
    var waiter = try fixture.store.observe(dispatchID: "d1").makeAsyncIterator()
    _ = await waiter.next()

    fixture.store.noteTerminalEvidence(
      surfaceID: fixture.binding.surfaceID,
      evidenceEpoch: UUID(),
      evidence: .needsInput
    )
    fixture.store.noteTerminalEvidence(
      surfaceID: fixture.binding.surfaceID,
      evidenceEpoch: fixture.binding.evidenceEpoch,
      evidence: .needsInput
    )
    let pending = try #require(fixture.store.snapshot(dispatchID: "d1"))
    let completed = try fixture.store.complete(
      dispatchID: "d1",
      outcome: .succeeded,
      summary: "Handled",
      callerSurfaceID: fixture.binding.surfaceID
    )

    #expect(await waiter.next() == .needsInput(pending))
    #expect(await waiter.next() == .changed(completed.snapshot))
  }

  @Test func oneSurfaceHoldsAtMostOnePendingRecord() throws {
    let store = makeStore(ids: ["d1", "d2"])
    let surfaceID = UUID()
    let binding = binding(surfaceID: surfaceID)
    _ = try store.issue()
    try store.bind(dispatchID: "d1", binding: binding)
    #expect(store.pendingSnapshot(surfaceID: surfaceID)?.record.id == "d1")
    #expect(store.pendingSnapshot(surfaceID: UUID()) == nil)

    _ = try store.issue()
    #expect(throws: AgentDispatchStoreError.surfacePending) {
      try store.bind(dispatchID: "d2", binding: binding)
    }
    #expect(store.pendingSnapshot(surfaceID: surfaceID)?.record.id == "d1")
    #expect(store.snapshot(dispatchID: "d2")?.binding == nil)
    // Rebinding the pending record itself stays idempotent.
    try store.bind(dispatchID: "d1", binding: binding)

    _ = try store.complete(dispatchID: "d1", outcome: .succeeded, summary: "Done", callerSurfaceID: surfaceID)
    #expect(store.pendingSnapshot(surfaceID: surfaceID) == nil)
    try store.bind(dispatchID: "d2", binding: binding)
    #expect(store.pendingSnapshot(surfaceID: surfaceID)?.record.id == "d2")
  }

  @Test func completionBySurfaceResolvesThePendingRecordThenReplaysTheLatestOne() throws {
    let store = makeStore(ids: ["d1", "d2"])
    let surfaceID = UUID()
    let binding = binding(surfaceID: surfaceID)
    _ = try store.issue()
    try store.bind(dispatchID: "d1", binding: binding)
    #expect(throws: AgentDispatchStoreError.notFound) {
      try store.complete(surfaceID: UUID(), outcome: .succeeded, summary: "Done")
    }

    let first = try store.complete(surfaceID: surfaceID, outcome: .succeeded, summary: "Round one")
    #expect(first.snapshot.record.id == "d1")
    #expect(!first.replayed)
    // With no pending record left, a retry replays the pane's latest receipt and a
    // conflicting retry is still rejected.
    let replay = try store.complete(surfaceID: surfaceID, outcome: .succeeded, summary: "Round one")
    #expect(replay.replayed)
    #expect(throws: AgentDispatchStoreError.alreadyCompleted) {
      try store.complete(surfaceID: surfaceID, outcome: .failed, summary: "Different")
    }

    _ = try store.issue()
    try store.bind(
      dispatchID: "d2",
      binding: AgentDispatchBinding(surfaceID: surfaceID, target: Self.target, evidenceEpoch: UUID())
    )
    let second = try store.complete(surfaceID: surfaceID, outcome: .failed, summary: "Round two")
    #expect(second.snapshot.record.id == "d2")
    #expect(!second.replayed)
    #expect(store.snapshot(dispatchID: "d1")?.record.state == .completed)
  }

  @Test func storeResetIsAppLifetimeReset() throws {
    let first = makeStore(ids: ["d1"])
    _ = try first.issue()
    let restarted = makeStore(ids: ["d2"])

    #expect(restarted.snapshot(dispatchID: "d1") == nil)
    #expect(throws: AgentDispatchStoreError.notFound) {
      try restarted.observe(dispatchID: "d1")
    }
  }

  private static let start = Date(timeIntervalSince1970: 1_000)

  private func makeStore(
    capacity: Int = 256,
    ids: [String],
    clock: any Clock<Duration> = ContinuousClock()
  ) -> AgentDispatchStore {
    let source = IDSource(ids)
    return AgentDispatchStore(
      capacity: capacity,
      now: { Self.start },
      makeID: { source.next() },
      coalescingClock: clock
    )
  }

  private func makeBoundStore(
    id: String,
    clock: any Clock<Duration> = ContinuousClock()
  ) throws -> (store: AgentDispatchStore, binding: AgentDispatchBinding) {
    let store = makeStore(ids: [id], clock: clock)
    _ = try store.issue()
    let binding = binding(surfaceID: UUID())
    try store.bind(dispatchID: id, binding: binding)
    return (store, binding)
  }

  private func binding(surfaceID: UUID) -> AgentDispatchBinding {
    AgentDispatchBinding(
      surfaceID: surfaceID,
      target: Self.target,
      evidenceEpoch: UUID()
    )
  }

  private func registerCoalescingTask() async {
    for _ in 0..<10 { await Task.yield() }
  }

  private static let target = TabTarget(
    worktree: TabTargetWorktree(
      id: "wt", name: "main", path: "/Projects/Prowl", rootPath: "/Projects/Prowl", kind: "git"
    ),
    tab: TabTargetTab(id: "tab", title: "Tab", selected: true),
    pane: TabTargetPane(id: "pane", title: "Pane", cwd: "/Projects/Prowl", focused: true)
  )
}

@MainActor
private final class IDSource {
  private var values: [String]

  init(_ values: [String]) {
    self.values = values
  }

  func next() -> String {
    values.removeFirst()
  }
}
