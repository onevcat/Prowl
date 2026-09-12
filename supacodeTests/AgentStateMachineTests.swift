import Testing

@testable import supacode

struct AgentStateMachineTests {
  private func screen(_ state: AgentRawState) -> AgentDetectionEvent {
    .screen(AgentScreenDetection(state: state, reason: .noRuleMatched))
  }

  @Test func screenOnlyDecisionPreservesRuleIdentifier() {
    var machine = AgentStateMachine()
    let detection = AgentScreenDetection(state: .working, reason: .matched(AgentScreenRuleID("pi.working")))
    #expect(machine.receive(.screen(detection), now: 0).reason.identifier == "pi.working")
  }

  @Test func screenOnlyPreservesUnknownForEveryAgent() {
    for _ in DetectedAgent.allCases {
      var machine = AgentStateMachine()
      for state in [AgentRawState.working, .blocked, .idle] {
        #expect(machine.receive(screen(state), now: 0).state == state)
        #expect(machine.receive(screen(.unknown), now: 1).state == state)
      }
    }
  }

  @Test func quietTurnNeverExpiresAndBlockedScreenWins() {
    var machine = AgentStateMachine()
    _ = machine.receive(screen(.idle), now: 0)
    _ = machine.receive(.inventory(["a"]), now: 0)
    #expect(machine.receive(.turnStarted(session: "a", turn: "1"), now: 1).state == .working)
    #expect(machine.receive(.tick, now: 10_000).state == .working)
    #expect(machine.receive(screen(.blocked), now: 10_001).state == .blocked)
    #expect(machine.receive(screen(.idle), now: 10_002).state == .working)
  }

  @Test func ambiguityRecoversAtClosedActivityDeadline() {
    var machine = AgentStateMachine()
    _ = machine.receive(screen(.idle), now: 0)
    _ = machine.receive(.inventory(["a", "b"]), now: 0)
    _ = machine.receive(.turnStarted(session: "a", turn: "1"), now: 0)
    _ = machine.receive(.turnEnded(session: "a", turn: "1"), now: 1)
    #expect(machine.receive(.turnStarted(session: "b", turn: "2"), now: 10).logSessionID == nil)
    #expect(machine.receive(.tick, now: 120.999).logSessionID == nil)
    #expect(machine.receive(.tick, now: 121).logSessionID == "b")
  }

  @Test func childOutlivesParentAndOldEndCannotCloseNewTurn() {
    var machine = AgentStateMachine()
    _ = machine.receive(screen(.idle), now: 0)
    _ = machine.receive(.inventory(["a"]), now: 0)
    _ = machine.receive(.turnStarted(session: "a", turn: "1"), now: 0)
    _ = machine.receive(.childStarted(root: "a", child: "c", work: "c1"), now: 1)
    #expect(machine.receive(.turnEnded(session: "a", turn: "1"), now: 2).hasOutstandingWork)
    #expect(machine.receive(.tick, now: 1000).state == .working)
    _ = machine.receive(.turnStarted(session: "a", turn: "2"), now: 1001)
    _ = machine.receive(.childEnded(root: "a", child: "c", work: "c1"), now: 1002)
    #expect(machine.receive(.turnEnded(session: "a", turn: "1"), now: 1003).state == .working)
  }

  @Test func logFailureUsesScreenHistoryRatherThanLogWorking() {
    var machine = AgentStateMachine()
    _ = machine.receive(screen(.idle), now: 0)
    _ = machine.receive(.inventory(["a"]), now: 0)
    _ = machine.receive(.turnStarted(session: "a", turn: "1"), now: 1)
    _ = machine.receive(screen(.unknown), now: 2)
    #expect(machine.receive(.unavailable, now: 3).state == .idle)
    #expect(machine.receive(.inventory(["a"]), now: 4).logSessionID == nil)
  }

  @Test func incompleteInventorySuspendsAuthorityWithoutLosingOpenWork() {
    var machine = AgentStateMachine()
    _ = machine.receive(screen(.idle), now: 0)
    _ = machine.receive(.inventory(["a"]), now: 0)
    _ = machine.receive(.turnStarted(session: "a", turn: "1"), now: 1)
    #expect(machine.receive(.suspended, now: 2).state == .idle)
    #expect(machine.receive(.inventory(["a"]), now: 3).state == .working)
  }
  @Test func completionFencesRetainedBlockerButNotNewInteraction() {
    var machine = AgentStateMachine()
    _ = machine.receive(.inventory(["a"]), now: 0)
    _ = machine.receive(.turnStarted(session: "a", turn: "1"), now: 1)
    _ = machine.receive(screen(.blocked), now: 2)
    #expect(machine.receive(.turnEnded(session: "a", turn: "1"), now: 3).state == .idle)
    #expect(machine.receive(screen(.blocked), now: 4).state == .idle)
    #expect(machine.receive(.interaction, now: 5).state == .blocked)
  }

  @Test func staleChildEndCannotCloseReusedChild() {
    var machine = AgentStateMachine()
    _ = machine.receive(.inventory(["a"]), now: 0)
    _ = machine.receive(.childStarted(root: "a", child: "c", work: "old"), now: 1)
    _ = machine.receive(.childStarted(root: "a", child: "c", work: "new"), now: 2)
    #expect(machine.receive(.childEnded(root: "a", child: "c", work: "old"), now: 3).hasOutstandingWork)
    #expect(!machine.receive(.childEnded(root: "a", child: "c", work: "new"), now: 4).hasOutstandingWork)
  }

  @Test func lateSchedulingNoticeCannotReplaceAnObservedChildTurn() {
    var machine = AgentStateMachine()
    _ = machine.receive(.inventory(["a"]), now: 0)
    _ = machine.receive(.turnStarted(session: "a", turn: "main"), now: 1)
    _ = machine.receive(.childStarted(root: "a", child: "c", work: "actual"), now: 2)
    _ = machine.receive(.childScheduled(root: "a", child: "c", work: "pending"), now: 3)
    _ = machine.receive(.turnEnded(session: "a", turn: "main"), now: 4)
    #expect(machine.receive(.childEnded(root: "a", child: "c", work: "actual"), now: 5).state == .idle)
  }

  @Test func changedBlockerWithSameRuleIsFreshEvidence() {
    var machine = AgentStateMachine()
    let blocker = AgentScreenDetection(state: .blocked, reason: .noRuleMatched)
    _ = machine.receive(.inventory(["a"]), now: 0)
    _ = machine.receive(.turnStarted(session: "a", turn: "1"), now: 1)
    _ = machine.receive(.screen(blocker, contentID: 1), now: 2)
    _ = machine.receive(.turnEnded(session: "a", turn: "1"), now: 3)
    #expect(machine.receive(.screen(blocker, contentID: 1), now: 4).state == .idle)
    #expect(machine.receive(.screen(blocker, contentID: 2), now: 5).state == .blocked)
  }

  @Test func childCompletionDoesNotRefreshMainActivityWindow() {
    var machine = AgentStateMachine()
    _ = machine.receive(.inventory(["a", "b"]), now: 0)
    _ = machine.receive(.turnStarted(session: "a", turn: "1"), now: 0)
    _ = machine.receive(.turnEnded(session: "a", turn: "1"), now: 1)
    _ = machine.receive(.childStarted(root: "a", child: "c", work: "1"), now: 2)
    _ = machine.receive(.turnStarted(session: "b", turn: "2"), now: 10)
    #expect(machine.receive(.tick, now: 1000).logSessionID == nil)
    #expect(machine.receive(.childEnded(root: "a", child: "c", work: "1"), now: 1001).logSessionID == "b")
  }

  @Test func suspensionRecoveryRetainsCompletedFrameFence() {
    for state in [AgentRawState.working, .blocked] {
      var machine = AgentStateMachine()
      _ = machine.receive(.inventory(["a"]), now: 0)
      _ = machine.receive(.turnStarted(session: "a", turn: "1"), now: 0)
      _ = machine.receive(screen(state), now: 0)
      _ = machine.receive(.turnEnded(session: "a", turn: "1"), now: 1)
      #expect(machine.receive(.suspended, now: 2).state == .idle)
      #expect(machine.receive(.inventory(["a"]), now: 3).state == .idle)
    }
  }

  @Test func activityExpiryDoesNotReviveCompletedFrame() {
    for state in [AgentRawState.working, .blocked] {
      var machine = AgentStateMachine()
      _ = machine.receive(.inventory(["a"]), now: 0)
      _ = machine.receive(.turnStarted(session: "a", turn: "1"), now: 0)
      _ = machine.receive(screen(state), now: 0)
      _ = machine.receive(.turnEnded(session: "a", turn: "1"), now: 1)
      #expect(machine.receive(.tick, now: 121).state == .idle)
      #expect(machine.decision.logSessionID == nil)
      #expect(machine.receive(.interaction, now: 122).state == state)
    }
  }

  @Test func completionFenceDoesNotHideAnotherRootsBlocker() {
    var machine = AgentStateMachine()
    _ = machine.receive(.inventory(["a", "b"]), now: 0)
    _ = machine.receive(.turnStarted(session: "a", turn: "1"), now: 0)
    _ = machine.receive(screen(.blocked), now: 0)
    _ = machine.receive(.turnEnded(session: "a", turn: "1"), now: 1)
    #expect(machine.receive(.childStarted(root: "b", child: "c", work: "1"), now: 122).state == .blocked)
  }

}
