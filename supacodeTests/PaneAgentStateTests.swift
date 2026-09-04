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

  @Test(arguments: [DetectedAgent.claude, .codex, .gemini])
  func workingIsStickyForShortIdleGap(agent: DetectedAgent) {
    let now = Date(timeIntervalSince1970: 100)
    var lastWorking: Date?

    let working = stabilizeAgentState(
      agent: agent,
      previous: .idle,
      raw: .working,
      now: now,
      lastWorkingAt: &lastWorking
    )
    #expect(working == .working)

    let stillWorking = stabilizeAgentState(
      agent: agent,
      previous: .working,
      raw: .idle,
      now: now.addingTimeInterval(2.9),
      lastWorkingAt: &lastWorking
    )
    #expect(stillWorking == .working)
  }

  @Test(arguments: [DetectedAgent.claude, .codex])
  func transitionsToIdleAfterStickyWindow(agent: DetectedAgent) {
    let now = Date(timeIntervalSince1970: 100)
    var lastWorking: Date? = now

    let idle = stabilizeAgentState(
      agent: agent,
      previous: .working,
      raw: .idle,
      now: now.addingTimeInterval(3.001),
      lastWorkingAt: &lastWorking
    )

    #expect(idle == .idle)
  }

  @Test(arguments: DetectedAgent.allCases)
  func changingIdleScreenRefreshesWorkingHold(agent: DetectedAgent) {
    let now = Date(timeIntervalSince1970: 100)
    let changedAt = now.addingTimeInterval(10)
    var lastWorking: Date? = now

    let held = stabilizeAgentState(
      agent: agent,
      previous: .working,
      raw: .idle,
      screenChanged: true,
      now: changedAt,
      lastWorkingAt: &lastWorking
    )

    #expect(held == .working)
    #expect(lastWorking == changedAt)

    let idle = stabilizeAgentState(
      agent: agent,
      previous: held,
      raw: .idle,
      now: changedAt.addingTimeInterval(3.001),
      lastWorkingAt: &lastWorking
    )
    #expect(idle == .idle)
  }

  @Test func changingScreenDoesNotPromoteIdleAgent() {
    let now = Date(timeIntervalSince1970: 100)
    var lastWorking: Date?

    let idle = stabilizeAgentState(
      agent: .codex,
      previous: .idle,
      raw: .idle,
      screenChanged: true,
      now: now,
      lastWorkingAt: &lastWorking
    )

    #expect(idle == .idle)
    #expect(lastWorking == nil)
  }

  @Test func blockedBypassesStickyWindow() {
    let now = Date(timeIntervalSince1970: 100)
    var lastWorking: Date? = now

    let blocked = stabilizeAgentState(
      agent: .claude,
      previous: .working,
      raw: .blocked,
      screenChanged: true,
      now: now.addingTimeInterval(0.3),
      lastWorkingAt: &lastWorking
    )

    #expect(blocked == .blocked)
  }

  @Test func unknownObservationKeepsPreviousStateAndRefreshesHold() {
    let now = Date(timeIntervalSince1970: 100)
    var lastWorking: Date? = now
    let later = now.addingTimeInterval(10)

    let held = stabilizeAgentState(
      agent: .claude,
      previous: .working,
      raw: .unknown,
      now: later,
      lastWorkingAt: &lastWorking
    )

    #expect(held == .working)
    #expect(lastWorking == later)

    var noHistory: Date?
    let idle = stabilizeAgentState(
      agent: .claude,
      previous: .idle,
      raw: .unknown,
      now: later,
      lastWorkingAt: &noHistory
    )

    #expect(idle == .idle)
    #expect(noHistory == nil)
  }

  @Test func unknownObservationWithoutHistoryStaysUnknown() {
    let now = Date(timeIntervalSince1970: 100)
    var lastWorking: Date?

    let unknown = stabilizeAgentState(
      agent: .claude,
      previous: .unknown,
      raw: .unknown,
      now: now,
      lastWorkingAt: &lastWorking
    )

    #expect(unknown == .unknown)
  }

  @Test func presenceRequiresSixMissesBeforeRelease() {
    var presence = AgentDetectionPresence(currentAgent: .codex)

    for _ in 0..<5 {
      #expect(presence.update(detectedAgent: nil) == .codex)
    }
    #expect(presence.update(detectedAgent: nil) == nil)
    #expect(presence.currentAgent == nil)
  }

  @Test func isBusyReflectsWorkingAndBlockedDetectedAgents() {
    #expect(PaneAgentState(detectedAgent: .claude, state: .working).isBusy)
    #expect(PaneAgentState(detectedAgent: .claude, state: .blocked).isBusy)
    #expect(!PaneAgentState(detectedAgent: .claude, state: .idle).isBusy)
    // Unseen idle surfaces display as `.done`, which must not count as busy.
    #expect(!PaneAgentState(detectedAgent: .claude, state: .idle, seen: false).isBusy)
    // A plain shell (no detected agent) is never busy, even mid-output.
    #expect(!PaneAgentState(detectedAgent: nil, state: .working).isBusy)
  }

  @Test func launchObservationRetainsOnlyForSameProcess() {
    let observation = AgentLaunchObservation(model: "gpt-5.4", executionMode: .unrestricted)
    let previous = PaneAgentState(agentProcessID: 42, launchObservation: observation)

    #expect(
      PaneAgentState.retainedLaunchObservation(
        observed: nil,
        previous: previous,
        identifiedPID: 42
      ) == observation
    )
    #expect(
      PaneAgentState.retainedLaunchObservation(
        observed: nil,
        previous: previous,
        identifiedPID: 43
      ) == nil
    )
  }

  @Test func launchProcessStaysStickyWhenASampleTransientlyDropsIt() {
    // A complete sample bound the launcher (100). If the next `proc_listpids` transiently
    // omits 100, `launchProcessID(of:)` returns the engine (101); keeping the previous launch
    // process — still a live ancestor of 101 — prevents a spurious process-replacement.
    let previous = PaneAgentState(agentProcessID: 101, launchProcessID: 100)
    #expect(
      PaneAgentState.retainedLaunchProcessID(
        identifiedLaunchProcessID: 101,
        identifiedProcessID: 101,
        previous: previous,
        isLiveAncestor: { ancestor, descendant in ancestor == 100 && descendant == 101 }
      ) == 100)
  }

  @Test func launchProcessMovesWhenThePreviousLauncherIsGone() {
    // A genuine relaunch: the old launcher is no longer an ancestor of the identified process.
    let previous = PaneAgentState(agentProcessID: 201, launchProcessID: 100)
    #expect(
      PaneAgentState.retainedLaunchProcessID(
        identifiedLaunchProcessID: 200,
        identifiedProcessID: 201,
        previous: previous,
        isLiveAncestor: { _, _ in false }
      ) == 200)
  }

  @Test func launchProcessUsesTheIdentifiedRootWhenUnchangedOrFirstSeen() {
    // Steady state (engine child rebinding keeps the same launch root) and the first bind.
    #expect(
      PaneAgentState.retainedLaunchProcessID(
        identifiedLaunchProcessID: 100,
        identifiedProcessID: 102,
        previous: PaneAgentState(agentProcessID: 101, launchProcessID: 100),
        isLiveAncestor: { _, _ in
          Issue.record("must not probe when the root is unchanged")
          return false
        }
      ) == 100)
    #expect(
      PaneAgentState.retainedLaunchProcessID(
        identifiedLaunchProcessID: 100,
        identifiedProcessID: 100,
        previous: PaneAgentState(),
        isLiveAncestor: { _, _ in false }
      ) == 100)
  }

  @Test func launchProcessHoldsAcrossAFullProbeGap() {
    // No agent identified this poll: keep the last known launch process untouched.
    #expect(
      PaneAgentState.retainedLaunchProcessID(
        identifiedLaunchProcessID: nil,
        identifiedProcessID: nil,
        previous: PaneAgentState(agentProcessID: 101, launchProcessID: 100),
        isLiveAncestor: { _, _ in false }
      ) == 100)
  }
}
