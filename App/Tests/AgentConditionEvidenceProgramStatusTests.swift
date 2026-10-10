import Foundation
import ProwlCLIShared
import Testing

@testable import Prowl

/// Readiness under OSC 7501 (docs-ai 079 slice 2), through the real condition builders
/// that `agents wait`, `agents dispatch`, and the workflow role wait share. The snapshot
/// carries the coordinator's current decision next to the reducer entry, because the
/// entry drops reason-only changes and the published decision is held back during a
/// withdrawal.
@MainActor
struct AgentConditionEvidenceProgramStatusTests {
  nonisolated private static let start = Date(timeIntervalSince1970: 1_000)
  private let surfaceID = UUID()
  private let unmatched = AgentScreenDetection(state: .unknown, reason: .noRuleMatched)

  private func signal(_ kind: AgentSignal.Kind, at seconds: TimeInterval = 0) -> AgentSignal {
    AgentSignal(
      kind: kind, source: .hook(runtime: .claude, event: "Stop"), confidence: .exact,
      timestamp: Self.start.addingTimeInterval(seconds), sessionID: nil, detail: nil, claimedOrigin: nil)
  }

  private func entry(_ status: AgentDisplayState, decision: AgentStateDecision?) -> ActiveAgentEntry {
    ActiveAgentEntry(
      id: surfaceID, worktreeID: "w1", worktreeName: "App", workingDirectory: URL(fileURLWithPath: "/App"),
      tabID: TerminalTabID(rawValue: UUID()), paneTitle: "Agent", surfaceID: surfaceID, paneIndex: 0,
      iconLookupToken: "claude", agent: .claude, stateDecision: decision,
      rawState: status == .working ? .working : status == .blocked ? .blocked : .idle,
      displayState: status, lastChangedAt: Self.start)
  }

  private func snapshot(
    _ status: AgentDisplayState,
    entryDecision: AgentStateDecision?,
    current: AgentStateDecision?,
    signal: AgentSignal? = nil,
    screen: AgentScreenDetection? = nil,
    revision: UInt64 = 1
  ) -> AgentConditionSnapshot {
    AgentConditionSnapshot(
      agent: entry(status, decision: entryDecision), signal: signal, revision: revision, isLive: true,
      signals: .empty, screenDetection: screen, decision: current)
  }

  private func osc(
    _ reason: ProgramStatusReason, state: AgentRawState, outstanding: Bool = false
  ) -> AgentStateDecision {
    AgentStateDecision(state: state, reason: .programStatus(reason), hasOutstandingWork: outstanding)
  }

  @Test func oscIdleDecisionsAreIdleEvidenceWithAnUnmatchedScreen() {
    for reason in [ProgramStatusReason.idle, .done, .error] {
      let decision = osc(reason, state: .idle)
      let idle = snapshot(.idle, entryDecision: decision, current: decision, screen: unmatched)
      #expect(AgentConditionEvidence.normalizedState(idle) == "idle", "\(reason.identifier)")
      #expect(AgentConditionEvidence.idleVerdict(for: idle) == .settling("idle"))
    }
    // Without OSC authority the same unmatched frame is no evidence at all.
    let legacy = AgentStateDecision(state: .idle, reason: .screen(.noRuleMatched))
    let unknown = snapshot(.idle, entryDecision: legacy, current: legacy, screen: unmatched)
    #expect(AgentConditionEvidence.normalizedState(unknown) == "unknown")
  }

  @Test func reasonOnlyChangeReachesTheWaitThroughTheCurrentDecision() {
    // The reducer entry still says `screen.*` (emission dedup hides reason-only changes);
    // the coordinator's current decision says `osc.idle`.
    let stale = AgentStateDecision(state: .idle, reason: .fallback(.noLiveTurn))
    let live = osc(.idle, state: .idle)
    let moved = snapshot(.idle, entryDecision: stale, current: live, screen: unmatched)
    #expect(AgentConditionEvidence.normalizedState(moved) == "idle")
    let withoutCurrent = snapshot(.idle, entryDecision: stale, current: nil, screen: unmatched)
    #expect(AgentConditionEvidence.normalizedState(withoutCurrent) == "unknown")
  }

  @Test func waitArmedAfterAWithdrawalDoesNotUseTheWithdrawnOSCIdle() {
    // The published pane decision still carries `osc.idle` (publication waits for the
    // fresh observe); the machine already dropped it. The current decision wins.
    let published = osc(.idle, state: .idle)
    let current = AgentStateDecision(state: .idle, reason: .fallback(.logUnavailable))
    let armed = snapshot(.idle, entryDecision: published, current: current, screen: unmatched)
    #expect(AgentConditionEvidence.normalizedState(armed) == "unknown")
    #expect(AgentConditionEvidence.idleVerdict(for: armed) == .busy("unknown"))
  }

  @Test func blockedChildVetoesIdleAdmissionAndPostArmTurnEnded() {
    let child = osc(.childBlocked(.question), state: .blocked, outstanding: true)
    let turnEnded = signal(.turnEnded, at: 5)
    let blocked = snapshot(.blocked, entryDecision: child, current: child, signal: turnEnded)
    let baseline = AgentConditionEvidence.Baseline(
      revision: 0, changedSignal: nil, terminalSignal: nil, state: "working")

    #expect(AgentConditionEvidence.idleVerdict(for: blocked, baseline: baseline) == .busy("blocked"))
    #expect(
      AgentConditionEvidence.exactMatch(
        condition: .idle, snapshot: blocked, normalizedState: "blocked", baseline: baseline, minimumConfidence: .auto)
        == nil)
    // The entry's own decision has no outstanding work; the current one decides.
    let staleEntry = snapshot(
      .idle, entryDecision: osc(.done, state: .idle), current: child, signal: turnEnded)
    #expect(AgentConditionEvidence.idleVerdict(for: staleEntry, baseline: baseline) == .busy("idle"))
  }

  @Test func rootDoneWithChildWorkingReleasesTheWait() {
    // Child `working` never reaches the evidence: the root alone decides and a post-arm
    // `turn-ended` resolves the wait.
    let done = osc(.done, state: .idle)
    let turnEnded = signal(.turnEnded, at: 5)
    let idle = snapshot(.idle, entryDecision: done, current: done, signal: turnEnded, screen: unmatched)
    let baseline = AgentConditionEvidence.Baseline(
      revision: 0, changedSignal: nil, terminalSignal: nil, state: "working")
    #expect(AgentConditionEvidence.idleVerdict(for: idle, baseline: baseline) == .idle)
  }

  @Test func workflowRoleWaitHonoursTheChildBlockedVetoAndTheOSCDone() {
    let child = osc(.childBlocked(.permission), state: .blocked, outstanding: true)
    let preArm = signal(.turnEnded, at: 0)
    var policy = WorkflowRoleWaitPolicy()
    let blocked = snapshot(.blocked, entryDecision: child, current: child, signal: preArm)
    #expect(policy.observe(blocked, pendingDispatchID: nil, elapsedMilliseconds: 0) == nil)
    #expect(policy.observe(blocked, pendingDispatchID: nil, elapsedMilliseconds: 2_500) == nil)

    // The child's prompt is answered, the root reports `done`, and a post-arm
    // `turn-ended` arrives: the wait ends at once.
    let done = osc(.done, state: .idle)
    let released = snapshot(
      .idle, entryDecision: done, current: done, signal: signal(.turnEnded, at: 5), screen: unmatched, revision: 2)
    #expect(policy.observe(released, pendingDispatchID: nil, elapsedMilliseconds: 3_000) == .idle)
  }

  @Test func dispatchAdmissionUsesTheCurrentDecision() async throws {
    let child = osc(.childBlocked(.permission), state: .blocked, outstanding: true)
    let target = TabResolvedTarget(
      worktreeID: "w1", worktreeName: "App", worktreePath: "/App", worktreeRootPath: "/App", worktreeKind: "git",
      tabID: UUID().uuidString, tabTitle: "Agent", tabSelected: true, paneID: surfaceID.uuidString,
      paneTitle: "Agent", paneCWD: "/App", paneFocused: false)
    let handler = AgentDispatchCommandHandler(
      resolveTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        self.snapshot(.idle, entryDecision: osc(.done, state: .idle), current: child)
      }
    )
    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json, command: .agentsDispatch(.init(pane: surfaceID.uuidString, prompt: "next")))
    )
    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.dispatchTargetBusy)
  }
}
