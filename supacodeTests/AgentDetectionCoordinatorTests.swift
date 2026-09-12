import Foundation
import Testing

@testable import supacode

@MainActor
struct AgentDetectionCoordinatorTests {
  private let generation = AgentProcessGeneration(pid: 42, startedAt: Date(timeIntervalSince1970: 1))
  private let idle = AgentScreenDetection(state: .idle, reason: .noRuleMatched)

  @Test func nonCodexAgentsNeverAcquireLogs() async {
    for agent in DetectedAgent.allCases where agent != .codex {
      let coordinator = AgentDetectionCoordinator(sample: { _, _ in
        Issue.record("Screen-only agent attempted log acquisition")
        return [.unavailable]
      })
      let decision = await coordinator.observe(agent: agent, process: generation, screen: idle, configRoot: nil)
      #expect(decision?.state == .idle)
      #expect(decision?.logSessionID == nil)
    }
  }

  @Test(arguments: DetectedAgent.allCases)
  func screenFallbackRetainsUnknownAndAcceptsDefiniteTransitions(agent: DetectedAgent) async {
    let coordinator = AgentDetectionCoordinator(sample: { _, _ in [.unavailable] })
    for raw in [AgentRawState.unknown, .working, .blocked, .idle] {
      let definite = await coordinator.observe(
        agent: agent, process: generation,
        screen: AgentScreenDetection(state: raw, reason: .noRuleMatched), configRoot: nil)
      #expect(definite?.state == raw)
      let held = await coordinator.observe(
        agent: agent, process: nil,
        screen: AgentScreenDetection(state: .unknown, reason: .noRuleMatched), configRoot: nil)
      #expect(held?.state == raw)
    }
  }

  @Test func invalidationRejectsSuspendedProviderResult() async {
    var continuation: CheckedContinuation<[AgentDetectionEvent], Never>?
    let entered = AsyncStream<Void>.makeStream()
    let coordinator = AgentDetectionCoordinator(sample: { _, _ in
      await withCheckedContinuation {
        continuation = $0
        entered.continuation.yield(())
      }
    })
    let pending = Task { await coordinator.observe(agent: .codex, process: generation, screen: idle, configRoot: nil) }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    coordinator.invalidate()
    continuation?.resume(returning: [.inventory(["old"]), .turnStarted(session: "old", turn: "1")])
    #expect(await pending.value == nil)
  }

  @Test func screenOnlyProbeGapRetainsStableScreenState() async {
    let coordinator = AgentDetectionCoordinator()
    _ = await coordinator.observe(
      agent: .claude, process: generation,
      screen: AgentScreenDetection(state: .working, reason: .noRuleMatched), configRoot: nil)
    let decision = await coordinator.observe(
      agent: .claude, process: nil,
      screen: AgentScreenDetection(state: .unknown, reason: .noRuleMatched), configRoot: nil)
    #expect(decision?.state == .working)
  }

  @Test func processReplacementDiscardsOldOpenWork() async {
    var calls = 0
    let coordinator = AgentDetectionCoordinator(sample: { _, _ in
      calls += 1
      return calls == 1 ? [.inventory(["a"]), .turnStarted(session: "a", turn: "1")] : [.inventory(["a"])]
    })
    #expect(
      await coordinator.observe(agent: .codex, process: generation, screen: idle, configRoot: nil)?.state == .working)
    let replacement = AgentProcessGeneration(pid: 42, startedAt: generation.startedAt.addingTimeInterval(1))
    #expect(
      await coordinator.observe(agent: .codex, process: replacement, screen: idle, configRoot: nil)?.state == .idle)
  }
  @Test func overlappingObservationsApplyConsumedCompletionExactlyOnce() async {
    var calls = 0
    var resume: CheckedContinuation<[AgentDetectionEvent], Never>?
    let entered = AsyncStream<Void>.makeStream()
    let coordinator = AgentDetectionCoordinator(sample: { _, _ in
      calls += 1
      if calls == 1 { return [.inventory(["a"]), .turnStarted(session: "a", turn: "1")] }
      if calls == 2 {
        return await withCheckedContinuation {
          resume = $0
          entered.continuation.yield(())
        }
      }
      return [.inventory(["a"])]
    })
    _ = await coordinator.observe(agent: .codex, process: generation, screen: idle, configRoot: nil)
    let first = Task { await coordinator.observe(agent: .codex, process: generation, screen: idle, configRoot: nil) }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    let second = Task {
      entered.continuation.yield(())
      return await coordinator.observe(agent: .codex, process: generation, screen: idle, configRoot: nil)
    }
    _ = await iterator.next()
    resume?.resume(returning: [.turnEnded(session: "a", turn: "1")])
    #expect(await first.value?.state == .idle)
    #expect(await second.value?.state == .idle)
    let final = await coordinator.observe(agent: .codex, process: generation, screen: idle, configRoot: nil)
    #expect(final?.hasOutstandingWork == false)
  }

  @Test func codexProbeGapRetainsTurnAndConsumesItsCompletion() async {
    var calls = 0
    let coordinator = AgentDetectionCoordinator(sample: { _, _ in
      calls += 1
      if calls == 1 { return [.inventory(["a"]), .turnStarted(session: "a", turn: "1")] }
      if calls == 3 { return [.inventory(["a"]), .turnEnded(session: "a", turn: "1")] }
      return [.inventory(["a"])]
    })
    _ = await coordinator.observe(agent: .codex, process: generation, screen: idle, configRoot: nil)
    let gap = await coordinator.observe(
      agent: .codex, process: nil,
      screen: AgentScreenDetection(state: .unknown, reason: .noRuleMatched), configRoot: nil)
    #expect(gap?.state == .working)
    #expect(gap?.hasOutstandingWork == true)
    let recovered = await coordinator.observe(agent: .codex, process: generation, screen: idle, configRoot: nil)
    #expect(recovered?.reason.identifier == "log.turnEnded")
    #expect(recovered?.hasOutstandingWork == false)
  }

  @Test func olderCapturedFrameCannotClearCompletionFence() async {
    var calls = 0
    let coordinator = AgentDetectionCoordinator(sample: { _, _ in
      calls += 1
      if calls == 1 { return [.inventory(["a"]), .turnStarted(session: "a", turn: "1")] }
      if calls == 2 { return [.turnEnded(session: "a", turn: "1")] }
      return [.inventory(["a"])]
    })
    let working = AgentScreenDetection(state: .working, reason: .noRuleMatched)
    _ = await coordinator.observe(agent: .codex, process: generation, screen: working, capturedAt: 1, configRoot: nil)
    #expect(
      await coordinator.observe(
        agent: .codex, process: generation, screen: working,
        capturedAt: 3, configRoot: nil)?.state == .idle)
    _ = await coordinator.observe(
      agent: .codex, process: generation,
      screen: AgentScreenDetection(state: .blocked, reason: .noRuleMatched), capturedAt: 2, configRoot: nil)
    #expect(
      await coordinator.observe(
        agent: .codex, process: generation, screen: working,
        capturedAt: 4, configRoot: nil)?.state == .idle)
  }

  @Test func queuedReplacementDoesNotInvalidateFollowingObservation() async {
    let entered = AsyncStream<Void>.makeStream()
    var resume: CheckedContinuation<[AgentDetectionEvent], Never>?
    var calls = 0
    let coordinator = AgentDetectionCoordinator(sample: { _, _ in
      calls += 1
      if calls == 1 {
        return await withCheckedContinuation {
          resume = $0
          entered.continuation.yield(())
        }
      }
      return [.inventory(["b"])]
    })
    let first = Task { await coordinator.observe(agent: .codex, process: generation, screen: idle, configRoot: nil) }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    let replacement = AgentProcessGeneration(pid: 43, startedAt: generation.startedAt)
    let second = Task {
      entered.continuation.yield(())
      return await coordinator.observe(agent: .codex, process: replacement, screen: idle, configRoot: nil)
    }
    _ = await iterator.next()
    let third = Task {
      entered.continuation.yield(())
      return await coordinator.observe(agent: .codex, process: replacement, screen: idle, configRoot: nil)
    }
    _ = await iterator.next()
    resume?.resume(returning: [.inventory(["a"])])
    _ = await first.value
    #expect(await second.value != nil)
    #expect(await third.value != nil)
  }

}
