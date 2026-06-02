import Foundation
import Testing

@testable import supacode

struct PaneAgentStateTests {
  @Test func displayStateDerivesDoneFromUnseenIdle() {
    var state = PaneAgentState(
      detectedAgent: .codex,
      fallbackState: .idle,
      state: .idle,
      seen: false,
      lastChangedAt: Date(timeIntervalSince1970: 0)
    )

    #expect(state.displayState == .done)
    state.seen = true
    #expect(state.displayState == .idle)
  }

  @Test func claudeWorkingIsStickyForShortIdleGap() {
    let now = Date(timeIntervalSince1970: 100)
    var lastWorking: Date?

    let working = stabilizeAgentState(
      agent: .claude,
      previous: .idle,
      raw: .working,
      now: now,
      lastWorkingAt: &lastWorking
    )
    #expect(working == .working)

    let stillWorking = stabilizeAgentState(
      agent: .claude,
      previous: .working,
      raw: .idle,
      now: now.addingTimeInterval(0.4),
      lastWorkingAt: &lastWorking
    )
    #expect(stillWorking == .working)
  }

  @Test func claudeTransitionsToIdleAfterStickyWindow() {
    let now = Date(timeIntervalSince1970: 100)
    var lastWorking: Date? = now

    let idle = stabilizeAgentState(
      agent: .claude,
      previous: .working,
      raw: .idle,
      now: now.addingTimeInterval(1.201),
      lastWorkingAt: &lastWorking
    )

    #expect(idle == .idle)
  }

  @Test func codexWorkingIsStickyForShortIdleGap() {
    let now = Date(timeIntervalSince1970: 100)
    var lastWorking: Date? = now

    let working = stabilizeAgentState(
      agent: .codex,
      previous: .working,
      raw: .idle,
      now: now.addingTimeInterval(0.4),
      lastWorkingAt: &lastWorking
    )

    #expect(working == .working)
    #expect(lastWorking == now)
  }

  @Test func codexTransitionsToIdleAfterStickyWindow() {
    let now = Date(timeIntervalSince1970: 100)
    var lastWorking: Date? = now

    let idle = stabilizeAgentState(
      agent: .codex,
      previous: .working,
      raw: .idle,
      now: now.addingTimeInterval(1.201),
      lastWorkingAt: &lastWorking
    )

    #expect(idle == .idle)
  }

  @Test func stickyWindowResetsWhenAgentChanges() {
    let now = Date(timeIntervalSince1970: 100)
    var lastWorking: Date? = now

    let idle = stabilizeAgentState(
      agent: .codex,
      previousAgent: .claude,
      previous: .working,
      raw: .idle,
      now: now.addingTimeInterval(0.4),
      lastWorkingAt: &lastWorking
    )

    #expect(idle == .idle)
    #expect(lastWorking == nil)
  }

  @Test func presenceRequiresSixMissesBeforeRelease() {
    var presence = AgentDetectionPresence(currentAgent: .codex)

    for _ in 0..<5 {
      #expect(presence.update(detectedAgent: nil) == .codex)
    }
    #expect(presence.update(detectedAgent: nil) == nil)
    #expect(presence.currentAgent == nil)
  }
}
