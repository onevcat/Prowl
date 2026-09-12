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
}
