import Testing

@testable import supacode

struct AgentNativeStateTests {
  private func snapshot(_ state: AgentRawState, session: String = "a", revision: Double = 1) -> AgentDetectionEvent {
    .native(AgentNativeSnapshot(sessionID: session, state: state, statusUpdatedAt: revision))
  }

  private func screen(_ state: AgentRawState, content: Int = 1) -> AgentDetectionEvent {
    .screen(AgentScreenDetection(state: state, reason: .noRuleMatched), contentID: content)
  }

  @Test func nativeWorkAndWaitingSurviveHistoryAndDoNotExpire() {
    var machine = AgentStateMachine()
    _ = machine.receive(screen(.idle), now: 0)
    #expect(machine.receive(snapshot(.working), now: 0).hasOutstandingWork)
    #expect(machine.receive(.tick, now: 10_000).state == .working)
    _ = machine.receive(screen(.unknown), now: 10_001)
    #expect(machine.receive(snapshot(.blocked, revision: 2), now: 10_002).state == .blocked)
    #expect(machine.decision.hasOutstandingWork)
  }

  @Test func initialNativeSnapshotDoesNotDismissAnExistingBlocker() {
    for state in [AgentRawState.idle, .working] {
      var machine = AgentStateMachine()
      _ = machine.receive(screen(.blocked), now: 0)
      #expect(machine.receive(snapshot(state), now: 1).state == .blocked)
    }
  }

  @Test func busyTransitionDoesNotDismissANewBlocker() {
    for previous in [AgentRawState.idle, .blocked] {
      var machine = AgentStateMachine()
      _ = machine.receive(screen(previous), now: 0)
      _ = machine.receive(snapshot(previous), now: 0)
      _ = machine.receive(screen(.blocked, content: 2), now: 1)
      #expect(machine.receive(snapshot(.working, revision: 2), now: 2).state == .blocked)
    }
  }

  @Test func completionFencesRetainedScreenButFreshBlockerWins() {
    var machine = AgentStateMachine()
    _ = machine.receive(screen(.working), now: 0)
    _ = machine.receive(snapshot(.working), now: 0)
    #expect(machine.receive(snapshot(.idle, revision: 2), now: 1).state == .idle)
    #expect(machine.receive(screen(.working), now: 2).state == .idle)
    #expect(machine.receive(snapshot(.idle, revision: 2), now: 3).state == .idle)
    #expect(machine.receive(screen(.blocked, content: 2), now: 4).state == .blocked)
    #expect(machine.receive(snapshot(.idle, revision: 2), now: 5).state == .blocked)
    #expect(machine.receive(snapshot(.idle, revision: 3), now: 6).state == .idle)
  }

  @Test func sessionSwitchAndOlderSnapshotCannotBorrowWork() {
    var machine = AgentStateMachine()
    _ = machine.receive(screen(.idle), now: 0)
    _ = machine.receive(snapshot(.working), now: 0)
    #expect(machine.receive(snapshot(.idle, session: "b", revision: 2), now: 1).state == .idle)
    #expect(machine.receive(snapshot(.working, session: "b", revision: 1), now: 2).state == .idle)
    #expect(!machine.decision.hasOutstandingWork)
  }

  @Test func suspensionUsesScreenAndRecoveryUsesCurrentSnapshot() {
    var machine = AgentStateMachine()
    _ = machine.receive(screen(.idle), now: 0)
    _ = machine.receive(snapshot(.working), now: 0)
    #expect(machine.receive(.suspended, now: 1).state == .idle)
    #expect(machine.receive(snapshot(.working), now: 2).state == .working)
    #expect(machine.receive(.unavailable, now: 3).state == .idle)
  }

  @Test func suspendedCompletedSnapshotCannotReviveRetainedWorking() {
    var machine = AgentStateMachine()
    _ = machine.receive(screen(.working), now: 0)
    _ = machine.receive(snapshot(.working), now: 0)
    _ = machine.receive(snapshot(.idle, revision: 2), now: 1)
    #expect(machine.receive(.suspended, now: 2).state == .idle)
    #expect(machine.receive(screen(.blocked, content: 2), now: 3).state == .blocked)
  }

  @Test func independentProcessesWithSharedSessionStayIndependent() {
    var busy = AgentStateMachine()
    var idle = AgentStateMachine()
    _ = busy.receive(screen(.idle), now: 0)
    _ = idle.receive(screen(.idle), now: 0)
    #expect(busy.receive(snapshot(.working), now: 1).state == .working)
    #expect(idle.receive(snapshot(.idle), now: 1).state == .idle)
  }
}
