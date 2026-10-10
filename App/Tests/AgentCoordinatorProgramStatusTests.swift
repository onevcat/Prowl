import Foundation
import Testing

@testable import Prowl

/// OSC 7501 inside the coordinator (docs-ai 079 slice 2): the attribution fence against
/// the bound process generation, the support table, the push path, and the authority
/// epoch that discards provider samples which were in flight when OSC took over.
@MainActor
struct AgentCoordinatorProgramStatusTests {
  private let started = Date(timeIntervalSince1970: 1_000)
  private var generation: AgentProcessGeneration { AgentProcessGeneration(pid: 42, startedAt: started) }
  private let idle = AgentScreenDetection(state: .idle, reason: .noRuleMatched)
  private let working = AgentScreenDetection(state: .working, reason: .noRuleMatched)
  private let legacyWorking = AgentScreenDetection(state: .working, reason: .legacyDetector)

  private func store(
    _ reports: [(GhosttyProgramStatusReport, TimeInterval)]
  ) -> ProgramStatusRecordStore {
    var store = ProgramStatusRecordStore()
    for (report, offset) in reports {
      store.apply(report, arrivedAt: started.addingTimeInterval(offset))
    }
    return store
  }

  private func report(
    _ state: GhosttyProgramStatusReport.State, id: String = "", app: String? = "claude-code",
    kind: GhosttyProgramStatusReport.Kind? = nil
  ) -> GhosttyProgramStatusReport {
    GhosttyProgramStatusReport(state: state, kind: kind, id: id, app: app)
  }

  private func verified(
    sample: AgentDetectionCoordinator.Sample? = nil,
    log: @escaping (String) -> Void = { _ in }
  ) -> AgentDetectionCoordinator {
    AgentDetectionCoordinator(sample: sample, support: { _ in .verified }, log: log)
  }

  @Test func unverifiedProducerNeverDrivesTheDecision() async {
    var lines: [String] = []
    let coordinator = AgentDetectionCoordinator(
      sample: { _, _ in [.unavailable] }, support: { _ in .unverified }, log: { lines.append($0) })
    let records = store([(report(.working), 1)])

    let decision = await coordinator.observe(
      agent: .claude, process: generation, screen: idle, configRoot: nil, programStatus: records)

    #expect(decision?.state == .idle)
    #expect(decision?.reason.isProgramStatus == false)
    #expect(coordinator.isDelegated == false)
    #expect(coordinator.receive(programStatus: records) == .none)
    // The disagreement is logged next to the live decision, with no message text.
    #expect(lines.count == 1)
    #expect(lines.first?.contains("osc=working/osc.working") == true)
    #expect(lines.first?.contains("live=idle/") == true)
  }

  @Test func shadowComparisonLogsOnTransitionOnly() async {
    var lines: [String] = []
    let coordinator = AgentDetectionCoordinator(
      sample: { _, _ in [.unavailable] }, support: { _ in .unverified }, log: { lines.append($0) })
    var records = store([(report(.working), 1)])
    for _ in 0..<3 {
      _ = await coordinator.observe(
        agent: .claude, process: generation, screen: idle, configRoot: nil, programStatus: records)
    }
    #expect(lines.count == 1)

    records.apply(report(.done), arrivedAt: started.addingTimeInterval(2))
    _ = coordinator.receive(programStatus: records)
    #expect(lines.count == 2)
    #expect(lines.last?.contains("osc=idle/osc.done") == true)
    _ = coordinator.receive(programStatus: records)
    #expect(lines.count == 2)
  }

  /// The production table (docs-ai 079 slice 3): Claude Code is verified; every other
  /// agent stays unverified until its own baseline replays inside Prowl.
  @Test func defaultTableVerifiesClaudeCodeOnly() async {
    for agent in DetectedAgent.allCases {
      let expected: ProgramStatusSupport = agent == .claude ? .verified : .unverified
      #expect(ProgramStatusSupport.level(for: agent) == expected, "\(agent)")
    }
    // With the default table a Claude root decides on the tick that sees it, the
    // schedule delegates, and the native registry is not sampled while it does.
    let claude = AgentDetectionCoordinator(sample: { _, _ in
      Issue.record("A verified Claude root must not sample the native provider")
      return [.unavailable]
    })
    let decision = await claude.observe(
      agent: .claude, process: generation, screen: idle, configRoot: nil,
      programStatus: store([(report(.working), 1)]))
    #expect(decision?.reason.identifier == "osc.working")
    #expect(decision?.screenReason == .delegated)
    #expect(claude.isDelegated)
    // Pi keeps its legacy detector until slice 4.
    let piCoordinator = AgentDetectionCoordinator(sample: { _, _ in [.unavailable] })
    let piDecision = await piCoordinator.observe(
      agent: .pi, process: generation, screen: legacyWorking, configRoot: nil,
      programStatus: store([(report(.idle, app: "pi"), 1)]))
    #expect(piDecision?.reason.identifier == "legacy.detector")
    #expect(piCoordinator.isDelegated == false)
  }

  @Test func verifiedEligibleRootDrivesTheDecisionAndDelegates() async {
    let coordinator = verified(sample: { _, _ in
      Issue.record("A delegated tick must not sample the provider")
      return [.unavailable]
    })
    let records = store([(report(.working), 1)])

    let first = await coordinator.observe(
      agent: .claude, process: generation, screen: idle, configRoot: nil, programStatus: records,
      delegated: true)

    #expect(first?.reason.identifier == "osc.working")
    #expect(first?.screenReason == .delegated)
    #expect(coordinator.isDelegated)
    #expect(coordinator.decision == first)
  }

  @Test func appMismatchIsNotEvidence() async {
    let coordinator = verified()
    let decision = await coordinator.observe(
      agent: .claude, process: generation, screen: idle, configRoot: nil,
      programStatus: store([(report(.working, app: "pi"), 1)]))
    #expect(decision?.reason.isProgramStatus == false)
    #expect(!coordinator.isDelegated)
  }

  @Test func recordsThatArrivedBeforeTheProcessStartedAreFencedPerRecord() async {
    // A predecessor left a blocked child behind (no `clear`) and a new root replaced
    // only the root record. The child inherits the new root's app but arrived before
    // this process started, so it cannot make the pane Blocked.
    let coordinator = verified()
    var records = store([(report(.working), -10), (report(.blocked, id: "ask", kind: .question), -9)])
    let stale = await coordinator.observe(
      agent: .claude, process: generation, screen: idle, configRoot: nil, programStatus: records)
    #expect(stale?.reason.isProgramStatus == false)

    records.apply(report(.working), arrivedAt: started.addingTimeInterval(1))
    let fresh = await coordinator.observe(
      agent: .claude, process: generation, screen: idle, configRoot: nil, programStatus: records)

    #expect(fresh?.state == .working)
    #expect(fresh?.reason.identifier == "osc.working")
  }

  @Test func sameAppRelaunchRebindsAndLosesThePredecessorsRecords() async {
    // Pi has no provider, so today it keeps its first generation; an OSC-capable agent
    // must rebind so the fence compares against the new process start. PID reuse is
    // the same change (same pid, later start).
    let coordinator = verified()
    let records = store([(report(.idle, app: "pi"), 1)])
    let bound = await coordinator.observe(
      agent: .pi, process: generation, screen: legacyWorking, configRoot: nil, programStatus: records)
    #expect(bound?.reason.identifier == "osc.idle")

    let relaunch = AgentProcessGeneration(pid: 42, startedAt: started.addingTimeInterval(5))
    let rebound = await coordinator.observe(
      agent: .pi, process: relaunch, screen: legacyWorking, configRoot: nil, programStatus: records)

    #expect(rebound?.reason.identifier == "legacy.detector")
    #expect(rebound?.state == .working)
    #expect(!coordinator.isDelegated)
  }

  @Test func reportBeforeTheFirstProbeWaitsForTheBinding() async {
    let coordinator = verified()
    let records = store([(report(.idle, app: "pi"), 1)])
    #expect(coordinator.receive(programStatus: records) == .none)
    #expect(coordinator.decision == nil)

    let decision = await coordinator.observe(
      agent: .pi, process: generation, screen: legacyWorking, configRoot: nil, programStatus: records)
    #expect(decision?.reason.identifier == "osc.idle")
  }

  @Test func probeGapKeepsTheBindingAndTheAuthority() async {
    let coordinator = verified()
    let records = store([(report(.working), 1)])
    _ = await coordinator.observe(
      agent: .claude, process: generation, screen: idle, configRoot: nil, programStatus: records)
    let held = await coordinator.observe(
      agent: .claude, process: nil, screen: AgentScreenDetection(state: .unknown, reason: .noRuleMatched),
      configRoot: nil, programStatus: records)
    #expect(held?.reason.identifier == "osc.working")
    #expect(coordinator.isDelegated)
  }

  @Test func verifiedPushPublishesAndWithdrawalDoesNot() async {
    let coordinator = verified()
    var records = store([(report(.idle), 1)])
    _ = await coordinator.observe(
      agent: .claude, process: generation, screen: idle, configRoot: nil, programStatus: records)

    records.apply(report(.working), arrivedAt: started.addingTimeInterval(2))
    guard case .decision(let pushed) = coordinator.receive(programStatus: records) else {
      Issue.record("Expected a published decision")
      return
    }
    #expect(pushed.reason.identifier == "osc.working")
    #expect(coordinator.decision == pushed)

    records.apply(report(.clear), arrivedAt: started.addingTimeInterval(3))
    #expect(coordinator.receive(programStatus: records) == .withdrawn)
    // The machine re-resolved at once; publication waits for a fresh observe.
    #expect(coordinator.decision?.reason.isProgramStatus == false)
    #expect(coordinator.lastProgramStatusWithdrawalAt != nil)
    #expect(!coordinator.isDelegated)
  }

  @Test func pushWithOnlyAMessageChangeReturnsTheSameDecision() async {
    let coordinator = verified()
    var records = store([(report(.working), 1)])
    _ = await coordinator.observe(
      agent: .claude, process: generation, screen: idle, configRoot: nil, programStatus: records)
    records.apply(
      GhosttyProgramStatusReport(state: .working, app: "claude-code", message: "Listing files"),
      arrivedAt: started.addingTimeInterval(2))
    guard case .decision(let pushed) = coordinator.receive(programStatus: records) else {
      Issue.record("Expected a decision")
      return
    }
    #expect(pushed == coordinator.decision)
    #expect(pushed.reason.identifier == "osc.working")
  }

  @Test func pushDuringASuspendedProviderSampleWinsAndTheLateSampleIsDiscarded() async {
    var resume: CheckedContinuation<[AgentDetectionEvent], Never>?
    let entered = AsyncStream<Void>.makeStream()
    var calls = 0
    let coordinator = verified(sample: { _, _ in
      calls += 1
      if calls == 1 { return [.native(AgentNativeSnapshot(sessionID: "s", state: .working, statusUpdatedAt: 1))] }
      if calls == 2 {
        return await withCheckedContinuation {
          resume = $0
          entered.continuation.yield(())
        }
      }
      return [.suspended]
    })
    let bound = await coordinator.observe(agent: .claude, process: generation, screen: working, configRoot: nil)
    #expect(bound?.reason.identifier == "native.working")

    let pending = Task {
      await coordinator.observe(agent: .claude, process: generation, screen: working, configRoot: nil)
    }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    var records = store([(report(.working), 1)])
    guard case .decision(let pushed) = coordinator.receive(programStatus: records) else {
      Issue.record("Expected a decision")
      return
    }
    #expect(pushed.reason.identifier == "osc.working")

    // The pre-authority snapshot lands late: applying it would recreate the native
    // snapshot and completed-frame fence the transition retired.
    resume?.resume(returning: [.native(AgentNativeSnapshot(sessionID: "s", state: .idle, statusUpdatedAt: 2))])
    let late = await pending.value
    #expect(late?.reason.identifier == "osc.working")

    records.apply(report(.clear), arrivedAt: started.addingTimeInterval(2))
    #expect(coordinator.receive(programStatus: records) == .withdrawn)
    // The first read after the withdrawal fails: the fallback is the screen, never a
    // pre-OSC Idle through the retained-completion path.
    let suspended = await coordinator.observe(
      agent: .claude, process: generation, screen: working, configRoot: nil, programStatus: records)
    #expect(suspended?.state == .working)
    #expect(suspended?.reason.identifier == "screen.logUnavailable")
  }

  @Test func tickThatTakesAuthorityDoesNotSampleTheProvider() async {
    // First binding on the ordinary active tick with a root already present: the
    // provider must not be sampled under authority, or its idle snapshot would
    // recreate the completed-frame fence and resurface after a withdrawal.
    var sampled = 0
    let coordinator = verified(sample: { _, _ in
      sampled += 1
      // The first read after the withdrawal fails; the next one is a fresh snapshot.
      return sampled == 1
        ? [.suspended] : [.native(AgentNativeSnapshot(sessionID: "s", state: .idle, statusUpdatedAt: 1))]
    })
    var records = store([(report(.working), 1)])
    let bound = await coordinator.observe(
      agent: .claude, process: generation, screen: working, configRoot: nil, programStatus: records)
    #expect(bound?.reason.identifier == "osc.working")
    #expect(sampled == 0)

    records.apply(report(.clear), arrivedAt: started.addingTimeInterval(2))
    #expect(coordinator.receive(programStatus: records) == .withdrawn)
    let first = await coordinator.observe(
      agent: .claude, process: generation, screen: working, configRoot: nil, programStatus: records)
    #expect(sampled == 1)
    #expect(first?.state == .working)
    #expect(first?.reason.identifier == "screen.logUnavailable")
    let resumed = await coordinator.observe(
      agent: .claude, process: generation, screen: working, configRoot: nil, programStatus: records)
    #expect(resumed?.reason.identifier == "native.idle")
  }

  @Test func invalidateBeforePushDropsThePush() async {
    let coordinator = verified()
    let records = store([(report(.working), 1)])
    _ = await coordinator.observe(
      agent: .claude, process: generation, screen: idle, configRoot: nil, programStatus: records)
    coordinator.invalidate()
    #expect(coordinator.receive(programStatus: records) == .none)
    #expect(coordinator.decision == nil)
  }

  @Test func staleSnapshotFromAPollCannotRollBackANewerPush() async {
    // A poll captured its store snapshot, then queued behind an observe that was
    // suspended at the provider; a push with a newer store landed in between. The
    // queued poll's older snapshot must neither roll the machine back nor replace
    // the coordinator's store.
    var resume: CheckedContinuation<[AgentDetectionEvent], Never>?
    let entered = AsyncStream<Void>.makeStream()
    var calls = 0
    let coordinator = verified(sample: { _, _ in
      calls += 1
      if calls == 1 {
        return await withCheckedContinuation {
          resume = $0
          entered.continuation.yield(())
        }
      }
      return [.suspended]
    })
    let stale = store([(report(.idle), 1)])
    let first = Task { await coordinator.observe(agent: .claude, process: generation, screen: idle, configRoot: nil) }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    var records = stale
    records.apply(report(.working), arrivedAt: started.addingTimeInterval(2))
    guard case .decision(let pushed) = coordinator.receive(programStatus: records) else {
      Issue.record("Expected a decision")
      return
    }
    #expect(pushed.reason.identifier == "osc.working")
    let queued = Task {
      await coordinator.observe(
        agent: .claude, process: generation, screen: idle, configRoot: nil, programStatus: stale)
    }
    resume?.resume(returning: [.suspended])
    #expect(await first.value?.reason.identifier == "osc.working")
    #expect(await queued.value?.reason.identifier == "osc.working")
    // The store the coordinator re-derives from on a rebind is still the newer one.
    records.apply(report(.done), arrivedAt: started.addingTimeInterval(3))
    guard case .decision(let later) = coordinator.receive(programStatus: records) else {
      Issue.record("Expected a decision")
      return
    }
    #expect(later.reason.identifier == "osc.done")
  }

}
