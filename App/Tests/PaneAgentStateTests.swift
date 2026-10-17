import Foundation
import Testing

@testable import Prowl

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

  @Test func presenceRequiresSixMissesBeforeRelease() {
    var presence = AgentDetectionPresence(currentAgent: .codex)

    for _ in 0..<5 {
      #expect(presence.update(detectedAgent: nil) == .codex)
    }
    #expect(presence.update(detectedAgent: nil) == nil)
    #expect(presence.currentAgent == nil)
  }

  @Test func commandFinishedMissReleasesAtOnceButOnlyThatMiss() {
    var presence = AgentDetectionPresence(currentAgent: .codex)
    #expect(presence.update(detectedAgent: nil) == .codex)
    #expect(presence.update(detectedAgent: nil, releaseOnMiss: true) == nil)
    #expect(presence.currentAgent == nil)
    #expect(presence.consecutiveMisses == 0)
    // A hit on the fresh sample is a hit; nothing is released.
    var held = AgentDetectionPresence(currentAgent: .claude)
    #expect(held.update(detectedAgent: .claude, releaseOnMiss: true) == .claude)
    #expect(held.consecutiveMisses == 0)
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
    let previous = PaneAgentState(agentProcess: .local(42), launchObservation: observation)

    #expect(
      PaneAgentState.retainedLaunchObservation(
        observed: nil,
        previous: previous,
        identified: .local(42)
      ) == observation
    )
    #expect(
      PaneAgentState.retainedLaunchObservation(
        observed: nil,
        previous: previous,
        identified: .local(43)
      ) == nil
    )
  }

  @Test func launchProcessStaysStickyWhenASampleTransientlyDropsIt() {
    // A complete sample bound the launcher (100). If the next `proc_listpids` transiently
    // omits 100, `launchProcess(of:)` returns the engine (101); keeping the previous launch
    // process — still a live ancestor of 101 — prevents a spurious process-replacement.
    let previous = PaneAgentState(agentProcess: .local(101), launchProcess: .local(100))
    #expect(
      PaneAgentState.retainedLaunchProcess(
        identifiedLaunch: .local(101),
        identifiedProcess: .local(101),
        previous: previous,
        isLiveAncestor: { ancestor, descendant in ancestor == .local(100) && descendant == .local(101) }
      ) == .local(100))
  }

  @Test func launchProcessMovesWhenThePreviousLauncherIsGone() {
    // A genuine relaunch: the old launcher is no longer an ancestor of the identified process.
    let previous = PaneAgentState(agentProcess: .local(201), launchProcess: .local(100))
    #expect(
      PaneAgentState.retainedLaunchProcess(
        identifiedLaunch: .local(200),
        identifiedProcess: .local(201),
        previous: previous,
        isLiveAncestor: { _, _ in false }
      ) == .local(200))
  }

  @Test func launchProcessUsesTheIdentifiedRootWhenUnchangedOrFirstSeen() {
    // Steady state (engine child rebinding keeps the same launch root) and the first bind.
    #expect(
      PaneAgentState.retainedLaunchProcess(
        identifiedLaunch: .local(100),
        identifiedProcess: .local(102),
        previous: PaneAgentState(agentProcess: .local(101), launchProcess: .local(100)),
        isLiveAncestor: { _, _ in
          Issue.record("must not probe when the root is unchanged")
          return false
        }
      ) == .local(100))
    #expect(
      PaneAgentState.retainedLaunchProcess(
        identifiedLaunch: .local(100),
        identifiedProcess: .local(100),
        previous: PaneAgentState(),
        isLiveAncestor: { _, _ in false }
      ) == .local(100))
  }

  @Test func launchProcessHoldsAcrossAFullProbeGap() {
    // No agent identified this poll: keep the last known launch process untouched.
    #expect(
      PaneAgentState.retainedLaunchProcess(
        identifiedLaunch: nil,
        identifiedProcess: nil,
        previous: PaneAgentState(agentProcess: .local(101), launchProcess: .local(100)),
        isLiveAncestor: { _, _ in false }
      ) == .local(100))
  }

  private static let mini = ConnectionKey(user: "onevcat", hostname: "mini.local")

  private static func remote(_ pid: Int32, start: String = "t1", host: ConnectionKey = mini) -> ProcessRef {
    .remote(RemoteProcessRef(connection: host, bootID: "boot", pid: pid, startToken: start))
  }

  @Test func remoteReferencesCompareTheWholeGeneration() {
    #expect(Self.remote(42) == Self.remote(42))
    // A reused pid with another start token, boot or host is another process.
    #expect(Self.remote(42) != Self.remote(42, start: "t2"))
    #expect(
      Self.remote(42)
        != .remote(RemoteProcessRef(connection: Self.mini, bootID: "other", pid: 42, startToken: "t1")))
    #expect(Self.remote(42) != Self.remote(42, host: ConnectionKey(user: "bob", hostname: "mini.local")))
    // The same number on this Mac is not the remote process.
    #expect(Self.remote(42) != .local(42))
    #expect(Self.remote(42).localPID == nil)
    #expect(ProcessRef.local(42).localPID == 42)
  }

  @Test func sessionAndLaunchObservationRetireOnOriginChange() {
    let session = AgentSession(id: "s", transcriptPath: nil, source: .processLog, confidence: .exact)
    let observation = AgentLaunchObservation(model: "m", executionMode: .unrestricted)
    let previous = PaneAgentState(agentProcess: .local(42), launchObservation: observation, session: session)
    let resolution = AgentSessionResolution(session: nil, isFresh: true)

    #expect(
      PaneAgentState.retainedSession(resolution: resolution, previous: previous, identified: Self.remote(42))
        .session == nil)
    #expect(
      PaneAgentState.retainedLaunchObservation(observed: nil, previous: previous, identified: Self.remote(42))
        == nil)
    let remote = PaneAgentState(agentProcess: Self.remote(42), session: session)
    #expect(
      PaneAgentState.retainedSession(resolution: resolution, previous: remote, identified: Self.remote(42, start: "t2"))
        .session == nil)
  }

  @Test func launchProcessOnAnotherOriginIsNeverRetained() {
    // A remote agent replaced a local launch inside the presence hold: the local launcher
    // is not consulted as an ancestor and the remote launch wins.
    let previous = PaneAgentState(agentProcess: .local(101), launchProcess: .local(100))
    #expect(
      PaneAgentState.retainedLaunchProcess(
        identifiedLaunch: Self.remote(100),
        identifiedProcess: Self.remote(101),
        previous: previous,
        isLiveAncestor: { _, _ in
          Issue.record("must not probe across origins")
          return true
        }
      ) == Self.remote(100))
  }

  @Test func localAncestryNeverAcceptsARemotePair() {
    let pid = getpid()
    #expect(WorktreeTerminalState.processIsLiveAncestor(ProcessRef.local(pid), of: ProcessRef.local(pid)))
    #expect(!WorktreeTerminalState.processIsLiveAncestor(Self.remote(pid), of: ProcessRef.local(pid)))
    #expect(!WorktreeTerminalState.processIsLiveAncestor(ProcessRef.local(pid), of: Self.remote(pid)))
  }

  @Test func remoteJobWalksItsOwnParentLinks() {
    let launcher = ForegroundProcess(ref: Self.remote(100), parentPID: 1, name: "droid", argv0: "droid", cmdline: nil)
    let engine = ForegroundProcess(ref: Self.remote(101), parentPID: 100, name: "droid", argv0: "droid", cmdline: nil)
    let job = ForegroundJob(processGroupID: 100, processes: [engine, launcher])
    #expect(job.launchProcess(of: Self.remote(101)) == Self.remote(100))
    let identified = identifyAgentInJob(job)
    #expect(identified?.process.ref == Self.remote(101) || identified?.process.ref == Self.remote(100))
    #expect(identified?.launchProcess == Self.remote(100))
    #expect(identified?.local == nil)
  }
}
