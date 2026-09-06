// supacodeTests/WorkflowRoleWaitPolicyTests.swift
// The idle wait of a `message` step (063 B3): baseline-aware exact evidence, exact needs-input
// precedence, detector stabilization, blocked grace, appearance grace, pending records.

import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct WorkflowRoleWaitPolicyTests {
  nonisolated private static let start = Date(timeIntervalSince1970: 1_000)
  private let surfaceID = UUID()

  private func signal(_ kind: AgentSignal.Kind, at seconds: TimeInterval = 0) -> AgentSignal {
    AgentSignal(
      kind: kind, source: .hook(runtime: .claude, event: "Stop"), confidence: .exact,
      timestamp: Self.start.addingTimeInterval(seconds), sessionID: nil, detail: nil, claimedOrigin: nil)
  }

  private func snapshot(
    _ status: AgentDisplayState?, signal: AgentSignal? = nil, revision: UInt64 = 1, live: Bool = true,
    channelCoversTurnEnded: Bool = true
  ) -> AgentConditionSnapshot {
    let agent = status.map { status in
      ActiveAgentEntry(
        id: surfaceID, worktreeID: "w1", worktreeName: "App", workingDirectory: URL(fileURLWithPath: "/App"),
        tabID: TerminalTabID(rawValue: UUID()), paneTitle: "Agent", surfaceID: surfaceID, paneIndex: 0,
        iconLookupToken: "claude", agent: .claude,
        rawState: status == .working ? .working : status == .blocked ? .blocked : .idle,
        displayState: status, lastChangedAt: Self.start)
    }
    let channels: [AgentSignalChannelPayload] =
      channelCoversTurnEnded
      ? [
        AgentSignalChannelPayload(
          source: "hook_claude", state: .verifiedLive, confidence: "exact",
          events: [.turnEnded, .needsInput, .sessionStart], lastSeenAt: "2026-08-30T00:00:00Z")
      ] : []
    return AgentConditionSnapshot(
      agent: agent, signal: signal, revision: revision, isLive: live,
      signals: AgentSignalsPayload(channels: channels, last: nil, lastBinding: nil))
  }

  @Test func aFreshExactTurnEndedEndsTheWaitEvenWhileTheScreenStillShowsWorking() {
    var policy = WorkflowRoleWaitPolicy()
    // Armed while the role works; the only signal so far is an old one.
    #expect(
      policy.observe(snapshot(.working, signal: signal(.sessionStart)), pendingDispatchID: nil, elapsedMilliseconds: 0)
        == nil)
    #expect(
      policy.observe(
        snapshot(.working, signal: signal(.sessionStart)), pendingDispatchID: nil, elapsedMilliseconds: 250) == nil)
    // A turn-ended that postdates the baseline is fresh exact evidence: no detector needed.
    #expect(
      policy.observe(
        snapshot(.working, signal: signal(.turnEnded, at: 5), revision: 2), pendingDispatchID: nil,
        elapsedMilliseconds: 500) == .idle)
  }

  @Test func aPreArmTurnEndedCountsOnceTheDetectorCorroboratesIt() {
    var policy = WorkflowRoleWaitPolicy()
    let stale = signal(.turnEnded)
    #expect(policy.observe(snapshot(.working, signal: stale), pendingDispatchID: nil, elapsedMilliseconds: 0) == nil)
    // The detector flips to idle: the pre-arm level is corroborated and counts at once (#733 D5).
    #expect(policy.observe(snapshot(.idle, signal: stale), pendingDispatchID: nil, elapsedMilliseconds: 250) == .idle)
  }

  @Test func aDetectorOnlyIdleViewMustStayStableForTwoSeconds() {
    var policy = WorkflowRoleWaitPolicy()
    let unhooked = { (status: AgentDisplayState) in self.snapshot(status, channelCoversTurnEnded: false) }
    #expect(policy.observe(unhooked(.working), pendingDispatchID: nil, elapsedMilliseconds: 0) == nil)
    #expect(policy.observe(unhooked(.idle), pendingDispatchID: nil, elapsedMilliseconds: 250) == nil)
    #expect(policy.observe(unhooked(.idle), pendingDispatchID: nil, elapsedMilliseconds: 2_000) == nil)
    // A flicker back to working restarts the stabilization.
    #expect(policy.observe(unhooked(.working), pendingDispatchID: nil, elapsedMilliseconds: 2_100) == nil)
    #expect(policy.observe(unhooked(.idle), pendingDispatchID: nil, elapsedMilliseconds: 2_250) == nil)
    #expect(policy.observe(unhooked(.idle), pendingDispatchID: nil, elapsedMilliseconds: 4_250) == .idle)
  }

  @Test func anExactNeedsInputOutranksADetectorIdleView() {
    var policy = WorkflowRoleWaitPolicy()
    // Fresh needs-input after the baseline, screen stale-idle: blocked, never idle.
    #expect(policy.observe(snapshot(.working), pendingDispatchID: nil, elapsedMilliseconds: 0) == nil)
    let asking = snapshot(.idle, signal: signal(.needsInput, at: 3), revision: 2)
    #expect(policy.observe(asking, pendingDispatchID: nil, elapsedMilliseconds: 250) == .blocked)
  }

  @Test func aPreArmNeedsInputCountsOnlyWithADetectorBlockedView() {
    var policy = WorkflowRoleWaitPolicy()
    let old = signal(.needsInput)
    #expect(policy.observe(snapshot(.working, signal: old), pendingDispatchID: nil, elapsedMilliseconds: 0) == nil)
    #expect(
      policy.observe(snapshot(.blocked, signal: old), pendingDispatchID: nil, elapsedMilliseconds: 250) == .blocked)
  }

  @Test func heuristicBlockedNeedsTheGraceAndWorkingResetsIt() {
    var policy = WorkflowRoleWaitPolicy(blockedGraceMilliseconds: 1_000)
    let unhooked = { (status: AgentDisplayState) in self.snapshot(status, channelCoversTurnEnded: false) }
    #expect(policy.observe(unhooked(.blocked), pendingDispatchID: nil, elapsedMilliseconds: 0) == nil)
    #expect(policy.observe(unhooked(.blocked), pendingDispatchID: nil, elapsedMilliseconds: 750) == nil)
    #expect(policy.observe(unhooked(.working), pendingDispatchID: nil, elapsedMilliseconds: 1_000) == nil)
    #expect(policy.observe(unhooked(.blocked), pendingDispatchID: nil, elapsedMilliseconds: 1_250) == nil)
    #expect(policy.observe(unhooked(.blocked), pendingDispatchID: nil, elapsedMilliseconds: 2_250) == .blocked)
  }

  @Test func goneAbsentAndForeignPendingRecordsEndTheWait() {
    var policy = WorkflowRoleWaitPolicy(appearanceGraceMilliseconds: 1_000)
    #expect(policy.observe(snapshot(nil), pendingDispatchID: nil, elapsedMilliseconds: 0) == nil)
    #expect(policy.observe(snapshot(nil), pendingDispatchID: nil, elapsedMilliseconds: 1_000) == .noAgent)
    var second = WorkflowRoleWaitPolicy()
    #expect(second.observe(snapshot(.idle, live: false), pendingDispatchID: nil, elapsedMilliseconds: 0) == .gone)
    var third = WorkflowRoleWaitPolicy()
    #expect(
      third.observe(snapshot(.idle), pendingDispatchID: "someone-elses", elapsedMilliseconds: 0)
        == .dispatchPending("someone-elses"))
  }
}
