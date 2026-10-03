import AppKit
import Clocks
import Testing

@testable import Prowl

@MainActor
struct MirrorScrollStateTests {
  @Test func agentWheelProfilesReserveChromeAndDoNotChangeUnknownAgents() {
    #expect(GhosttyMirrorPaneSource.wheelEvents(paneRows: 51, agent: .codex) == 13)
    #expect(GhosttyMirrorPaneSource.wheelEvents(paneRows: 51, agent: .claude) == 48)
    #expect(GhosttyMirrorPaneSource.wheelEvents(paneRows: 51, agent: nil) == 48)
    #expect(GhosttyMirrorPaneSource.wheelEvents(paneRows: 1, agent: .codex) == 1)
    #expect(GhosttyMirrorPaneSource.wheelEvents(paneRows: 3, agent: nil) == 1)
  }

  @Test func waitsForCorrelatedFramePresentationAndLimitsPendingInput() throws {
    let state = MirrorScrollState()
    state.didPresent(sequence: 4)
    let request = try #require(state.begin())
    #expect(state.begin() == nil)
    state.receiveResult(requestID: UUID(), sequence: 5)
    #expect(state.isLoading)
    state.receiveResult(requestID: request, sequence: 6)
    state.didPresent(sequence: 5)
    #expect(state.isLoading)
    #expect(state.completedRequestID == nil)
    state.didPresent(sequence: 6)
    #expect(!state.isLoading)
    #expect(state.error == nil)
    #expect(state.completedRequestID == request)
  }

  @Test func resultCanArriveAfterItsFrameWasPresented() throws {
    let state = MirrorScrollState()
    let request = try #require(state.begin())
    state.didPresent(sequence: 1)
    #expect(state.isLoading)
    state.receiveResult(requestID: request, sequence: 1)
    #expect(!state.isLoading)
  }

  @Test func staleFrameCannotConfirmNewInput() throws {
    let state = MirrorScrollState()
    state.didPresent(sequence: 9)
    let request = try #require(state.begin())
    state.receiveResult(requestID: request, sequence: 9)
    #expect(!state.isLoading)
    #expect(state.error != nil)
  }

  @Test func timeoutDoesNotRetryAndLateReplyCannotCompleteNextRequest() async throws {
    let clock = TestClock()
    let state = MirrorScrollState(clock: clock)
    let previous = try #require(state.begin())
    await clock.advance(by: .seconds(5))
    #expect(!state.isLoading)
    #expect(state.error?.contains("timed out") == true)
    #expect(state.completedRequestID == nil)
    let next = try #require(state.begin())
    state.receiveResult(requestID: previous, sequence: 1)
    state.didPresent(sequence: 1)
    #expect(state.requestID == next)
    await clock.advance()
    state.cancel()
    await clock.advance()
    try await clock.checkSuspension()
    #expect(!state.isLoading)
  }

  @Test func resetAllowsNewSubscriptionSequenceAndCancelsTimeout() async throws {
    let clock = TestClock()
    let state = MirrorScrollState(clock: clock)
    state.didPresent(sequence: 100)
    _ = state.begin()
    await clock.advance()
    state.reset()
    await clock.advance()
    try await clock.checkSuspension()
    let next = try #require(state.begin())
    state.didPresent(sequence: 1)
    state.receiveResult(requestID: next, sequence: 1)
    #expect(!state.isLoading)
    #expect(state.error == nil)
  }
}
