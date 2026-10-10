import Foundation
import Testing

@testable import Prowl

/// OSC 7501 inside the coordinator (docs-ai 079 slice 2): the attribution fence against
/// the bound process generation, the support table, the push path, and the authority
/// epoch that discards provider samples which were in flight when OSC took over.
@MainActor
struct AgentDetectionCoordinatorProgramStatusTests {
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

  @Test func defaultTableLeavesEveryAgentUnverified() async {
    for agent in DetectedAgent.allCases {
      #expect(ProgramStatusSupport.level(for: agent) == .unverified, "\(agent)")
    }
    let coordinator = AgentDetectionCoordinator(sample: { _, _ in [.unavailable] })
    let decision = await coordinator.observe(
      agent: .pi, process: generation, screen: legacyWorking, configRoot: nil,
      programStatus: store([(report(.idle, app: "pi"), 1)]))
    #expect(decision?.reason.identifier == "legacy.detector")
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
    var resume: CheckedContinuation<[AgentDetectionEvent], Never>?
    let entered = AsyncStream<Void>.makeStream()
    var calls = 0
    let coordinator = verified(sample: { _, _ in
      calls += 1
      if calls == 1 { return [.suspended] }
      return await withCheckedContinuation {
        resume = $0
        entered.continuation.yield(())
      }
    })
    var records = store([(report(.idle), 1)])
    // Bind with a withdrawn-looking state so the poll samples the provider.
    _ = await coordinator.observe(agent: .claude, process: generation, screen: idle, configRoot: nil)
    let snapshotBeforePush = records
    let pending = Task {
      await coordinator.observe(
        agent: .claude, process: generation, screen: idle, configRoot: nil, programStatus: snapshotBeforePush)
    }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    records.apply(report(.working), arrivedAt: started.addingTimeInterval(2))
    _ = coordinator.receive(programStatus: records)
    resume?.resume(returning: [.suspended])
    let polled = await pending.value
    #expect(polled?.reason.identifier == "osc.working")
  }
}
