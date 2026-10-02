import Testing

@testable import supacode

@MainActor
struct TerminalCloseConfirmationGateTests {
  @Test func runExecutesWhenGateIsFree() {
    let result = TerminalCloseConfirmationGate.run { true }
    #expect(result == true)
    #expect(TerminalCloseConfirmationGate.isPresenting == false)
  }

  @Test func nestedRunIsDropped() {
    var nestedResult: Bool? = false
    let outer = TerminalCloseConfirmationGate.run { () -> Bool in
      #expect(TerminalCloseConfirmationGate.isPresenting)
      nestedResult = TerminalCloseConfirmationGate.run { true }
      return true
    }
    #expect(outer == true)
    #expect(nestedResult == nil)
  }

  @Test func gateIsReleasedAfterRun() {
    _ = TerminalCloseConfirmationGate.run { true }
    let second = TerminalCloseConfirmationGate.run { false }
    #expect(second == false)
  }
}
