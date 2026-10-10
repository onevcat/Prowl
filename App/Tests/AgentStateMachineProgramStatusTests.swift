import Foundation
import Testing

@testable import Prowl

/// OSC 7501 evidence inside the pure state machine (docs-ai 079 slice 2): the root
/// record is the first-priority state evidence, a withdrawal falls back to the legacy
/// paths with their own reasons, and taking authority retires the facts the machine
/// will not refresh while the schedule is delegated.
struct AgentStateMachineProgramStatusTests {
  private typealias Kind = GhosttyProgramStatusReport.Kind

  private func screen(_ state: AgentRawState, reason: AgentScreenDetectionReason = .noRuleMatched) -> AgentDetectionEvent {
    .screen(AgentScreenDetection(state: state, reason: reason))
  }

  private func native(_ state: AgentRawState, revision: Double) -> AgentDetectionEvent {
    .native(AgentNativeSnapshot(sessionID: "s", state: state, statusUpdatedAt: revision))
  }

  private func evidence(
    root: ProgramStatusRecord.State,
    rootKind: Kind? = nil,
    blockedChild: ProgramStatusEvidence.BlockedChild? = nil
  ) -> ProgramStatusEvidence {
    ProgramStatusEvidence(root: root, rootKind: rootKind, blockedChild: blockedChild)
  }

  private func osc(
    _ root: ProgramStatusRecord.State,
    kind: Kind? = nil,
    blockedChild: ProgramStatusEvidence.BlockedChild? = nil,
    revision: UInt64
  ) -> AgentDetectionEvent {
    .programStatus(evidence(root: root, rootKind: kind, blockedChild: blockedChild), revision: revision)
  }

  @Test func rootRecordMapsToStateReasonAndOutstandingWork() {
    let cases: [(ProgramStatusRecord.State, Kind?, AgentRawState, String, Bool)] = [
      (.working, nil, .working, "osc.working", true),
      (.blocked, .permission, .blocked, "osc.blocked.permission", true),
      (.blocked, .question, .blocked, "osc.blocked.question", true),
      (.blocked, .auth, .blocked, "osc.blocked.auth", true),
      (.blocked, nil, .blocked, "osc.blocked.unspecified", true),
      (.idle, nil, .idle, "osc.idle", false),
      (.done, nil, .idle, "osc.done", false),
      (.error, nil, .idle, "osc.error", false),
    ]
    for (root, kind, state, identifier, outstanding) in cases {
      var machine = AgentStateMachine()
      _ = machine.receive(screen(.working), now: 0)
      let decision = machine.receive(osc(root, kind: kind, revision: 1), now: 1)
      #expect(decision.state == state, "\(identifier)")
      #expect(decision.reason.identifier == identifier)
      #expect(decision.hasOutstandingWork == outstanding, "\(identifier)")
      #expect(decision.logSessionID == nil)
      #expect(machine.hasProgramStatusAuthority)
    }
  }

  @Test func blockedChildVetoesIdleAndSetsOutstandingWork() {
    for kind in [Kind.permission, .question, .auth] {
      var machine = AgentStateMachine()
      let decision = machine.receive(
        osc(.done, blockedChild: ProgramStatusEvidence.BlockedChild(kind: kind), revision: 1), now: 0)
      #expect(decision.state == .blocked)
      #expect(decision.reason.identifier == "osc.childBlocked.\(kind.rawValue)")
      #expect(decision.hasOutstandingWork)
    }
    var machine = AgentStateMachine()
    let unspecified = machine.receive(
      osc(.working, blockedChild: ProgramStatusEvidence.BlockedChild(kind: nil), revision: 1), now: 0)
    #expect(unspecified.state == .blocked)
    #expect(unspecified.reason.identifier == "osc.childBlocked.unspecified")
  }

  @Test func blockedRootOutranksABlockedChild() {
    var machine = AgentStateMachine()
    let decision = machine.receive(
      osc(.blocked, kind: .permission, blockedChild: ProgramStatusEvidence.BlockedChild(kind: .question), revision: 1),
      now: 0)
    #expect(decision.reason.identifier == "osc.blocked.permission")
  }

  @Test func childWorkingIsNotEvidence() {
    // The evidence carries no child `working` at all: the fence leaves it in the store and
    // the pane follows the root. A root `done` with busy children is Idle without work.
    var machine = AgentStateMachine()
    let decision = machine.receive(osc(.done, revision: 1), now: 0)
    #expect(decision.state == .idle)
    #expect(!decision.hasOutstandingWork)
  }

  @Test func programStatusOutranksNativeLogAndScreen() {
    var machine = AgentStateMachine()
    _ = machine.receive(screen(.blocked), now: 0)
    _ = machine.receive(native(.working, revision: 1), now: 0)
    _ = machine.receive(.inventory(["a"]), now: 0)
    _ = machine.receive(.turnStarted(session: "a", turn: "1"), now: 0)
    let decision = machine.receive(osc(.idle, revision: 1), now: 1)
    #expect(decision.state == .idle)
    #expect(decision.reason.identifier == "osc.idle")
    // A later screen frame changes nothing while the root record is live.
    #expect(machine.receive(screen(.blocked), now: 2).state == .idle)
  }

  @Test func withdrawalFallsBackToScreenWithTheLegacyReason() {
    var machine = AgentStateMachine()
    _ = machine.receive(screen(.working, reason: .legacyDetector), now: 0)
    #expect(machine.receive(osc(.idle, revision: 1), now: 1).reason.identifier == "osc.idle")

    let decision = machine.receive(.programStatus(nil, revision: 2), now: 2)

    #expect(decision.state == .working)
    #expect(decision.reason.identifier == "legacy.detector")
    #expect(!machine.hasProgramStatusAuthority)
  }

  @Test func olderOrEqualRevisionIsIgnored() {
    var machine = AgentStateMachine()
    #expect(machine.receive(osc(.working, revision: 5), now: 0).state == .working)
    // A poll snapshot captured before a newer push cannot roll it back.
    #expect(machine.receive(osc(.idle, revision: 4), now: 1).state == .working)
    #expect(machine.receive(.programStatus(nil, revision: 5), now: 2).state == .working)
    #expect(machine.hasProgramStatusAuthority)
    #expect(machine.receive(osc(.idle, revision: 6), now: 3).state == .idle)
  }

  @Test func authorityRetiresTheNativeSnapshotAndCompletedFrameFence() {
    // Native idle fenced the unchanged working frame. With `.suspended` that fence survives
    // (068); the dedicated OSC transition must retire it so a withdrawal cannot publish a
    // pre-OSC Idle through `screen.retainedCompletion`.
    var machine = AgentStateMachine()
    _ = machine.receive(screen(.working), now: 0)
    _ = machine.receive(native(.working, revision: 1), now: 0)
    #expect(machine.receive(native(.idle, revision: 2), now: 1).state == .idle)
    #expect(machine.receive(screen(.working), now: 2).reason.identifier == "native.idle")

    #expect(machine.receive(osc(.working, revision: 1), now: 3).reason.identifier == "osc.working")
    let decision = machine.receive(.programStatus(nil, revision: 2), now: 4)

    #expect(decision.state == .working)
    #expect(decision.reason.identifier == "screen.logUnavailable")
  }

  @Test func withdrawalThenSuspendedFirstSampleDoesNotRevivePreOSCIdle() {
    var machine = AgentStateMachine()
    _ = machine.receive(screen(.working), now: 0)
    _ = machine.receive(native(.working, revision: 1), now: 0)
    _ = machine.receive(native(.idle, revision: 2), now: 1)
    _ = machine.receive(osc(.working, revision: 1), now: 2)
    #expect(machine.receive(osc(.done, revision: 2), now: 3).reason.identifier == "osc.done")
    _ = machine.receive(.programStatus(nil, revision: 3), now: 4)

    let decision = machine.receive(.suspended, now: 5)

    #expect(decision.state == .working)
    #expect(decision.reason.identifier == "screen.logUnavailable")
    // A fresh native snapshot resumes authority as before.
    #expect(machine.receive(native(.idle, revision: 3), now: 6).reason.identifier == "native.idle")
  }

  @Test func authorityLeavesHasLogProviderUntouched() {
    // Pi has no provider: after OSC authority ends, its fallback reason is still the
    // screen rule, never `screen.logUnavailable`, which only `.suspended` would set.
    var machine = AgentStateMachine()
    _ = machine.receive(screen(.idle, reason: .legacyDetector), now: 0)
    _ = machine.receive(osc(.working, revision: 1), now: 1)
    _ = machine.receive(.programStatus(nil, revision: 2), now: 2)
    #expect(machine.receive(screen(.working, reason: .legacyDetector), now: 3).reason.identifier == "legacy.detector")
  }

  @Test func authorityRetiresLogRecencyButKeepsOpenWorkAccounting() {
    var machine = AgentStateMachine()
    _ = machine.receive(screen(.idle), now: 0)
    _ = machine.receive(.inventory(["a"]), now: 0)
    _ = machine.receive(.turnStarted(session: "a", turn: "1"), now: 0)
    _ = machine.receive(.turnEnded(session: "a", turn: "1"), now: 1)
    #expect(machine.decision.reason.identifier == "log.turnEnded")

    _ = machine.receive(osc(.working, revision: 1), now: 2)
    let decision = machine.receive(.programStatus(nil, revision: 2), now: 3)

    // The completed root's recency was retired: no eligible root, log fallback.
    #expect(decision.reason.identifier == "screen.noLiveTurn")
    #expect(decision.state == .idle)
  }

  @Test func screenReasonUnderAuthorityIsTheDelegatedMarker() {
    var machine = AgentStateMachine()
    _ = machine.receive(screen(.working, reason: .matched(AgentScreenRuleID("pi.working"))), now: 0)
    let decision = machine.receive(osc(.idle, revision: 1), now: 1)
    #expect(decision.screenReason == .delegated)
    #expect(decision.screenReason?.identifier == "screen.delegated")
    let withdrawn = machine.receive(.programStatus(nil, revision: 2), now: 2)
    #expect(withdrawn.screenReason?.identifier == "pi.working")
  }

  @Test func evidenceDecisionIsThePureMappingSharedWithShadowComparison() {
    let decision = evidence(root: .blocked, rootKind: .auth).decision
    #expect(decision.state == .blocked)
    #expect(decision.reason == .programStatus(.blocked(.auth)))
    #expect(decision.hasOutstandingWork)
  }
}
