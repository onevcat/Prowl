import Testing

@testable import supacode

struct AgentStateMachineTests {
  private func screen(_ state: AgentRawState) -> AgentDetectionEvent {
    .screen(AgentScreenDetection(state: state, reason: .noRuleMatched))
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
}
