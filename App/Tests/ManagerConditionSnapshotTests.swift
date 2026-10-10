import Foundation
import ProwlCLIShared
import Testing

@testable import Prowl

/// The production condition-snapshot builder that `agents wait`, `agents dispatch`,
/// and the workflow runner share (docs-ai 079): it must carry the coordinator's
/// current decision, which neither the reducer entry (emission drops reason-only
/// changes) nor the published pane decision (held back during a withdrawal) does.
@MainActor
struct ManagerConditionSnapshotTests {
  private final class Probe {
    var job: ForegroundJob?
  }

  private func report(_ state: GhosttyProgramStatusReport.State) -> GhosttyProgramStatusReport {
    GhosttyProgramStatusReport(state: state, app: "claude-code")
  }

  private func entry(surfaceID: UUID, decision: AgentStateDecision?) -> ActiveAgentEntry {
    ActiveAgentEntry(
      id: surfaceID, worktreeID: "/tmp/repo/wt-1", worktreeName: "wt-1",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"), tabID: TerminalTabID(rawValue: UUID()),
      paneTitle: "Agent", surfaceID: surfaceID, paneIndex: 0, iconLookupToken: "claude", agent: .claude,
      stateDecision: decision, rawState: .idle, displayState: .idle, lastChangedAt: Date(timeIntervalSince1970: 0))
  }

  @Test func snapshotCarriesTheCoordinatorsCurrentDecision() async throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime(), skipsSurfaceCreationForTesting: true)
    let worktree = Worktree(
      id: "/tmp/repo/wt-1", name: "wt-1", detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"), repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"))
    let state = manager.state(for: worktree)
    let tabID = try #require(state.createTab())
    let surfaceID = try #require(state.focusedSurfaceId(in: tabID))
    let surface = try #require(state.surfaceView(for: surfaceID))
    let probe = Probe()
    probe.job = ForegroundJob(
      processGroupID: getpid(),
      processes: [
        ForegroundProcess(pid: getpid(), parentProcessID: getppid(), name: "claude", argv0: "claude", cmdline: "claude")
      ])
    state.agentProcessProbeForTesting = { _, _, _ in probe.job }
    state.programStatusSupportForTesting = { _ in .verified }
    state.agentDetectionTasks[surfaceID] = Task {}
    state.surfaceAgentStates[surfaceID] = PaneAgentState(lastChangedAt: Date())
    state.lastAgentScreenScanBySurface[surfaceID] = WorktreeTerminalState.AgentScreenScan(
      agent: .claude, text: "", detection: AgentScreenDetection(state: .idle, reason: .legacyDetector))
    #expect(
      await state.detectAgentState(
        for: surface, tabId: tabID,
        resolveSession: { _, _, _, _, _ in (nil, 0) }))
    let stale = entry(
      surfaceID: surfaceID, decision: AgentStateDecision(state: .idle, reason: .screen(.legacyDetector)))

    state.handleProgramStatus(report(.idle), surfaceID: surfaceID)
    let delegated = manager.agentConditionSnapshot(surfaceID: surfaceID, agent: stale)

    // The entry still says `legacy.detector`; the live decision says `osc.idle`.
    #expect(delegated.decision?.reason.identifier == "osc.idle")
    #expect(delegated.currentDecision?.reason.identifier == "osc.idle")
    #expect(delegated.agent?.stateDecision?.reason.identifier == "legacy.detector")
    #expect(delegated.isLive)
    #expect(delegated.screenDetection?.reason == .legacyDetector)
    #expect(AgentConditionEvidence.normalizedState(delegated) == "idle")

    // A withdrawal holds the pane publication back, but the current decision drops
    // the OSC reason at once, so a wait armed now cannot use it.
    state.handleProgramStatus(GhosttyProgramStatusReport(state: .clear), surfaceID: surfaceID)
    let published = state.surfaceAgentStates[surfaceID]?.decision
    #expect(published?.reason.identifier == "osc.idle")
    let withdrawn = manager.agentConditionSnapshot(
      surfaceID: surfaceID, agent: entry(surfaceID: surfaceID, decision: published))
    #expect(withdrawn.decision?.reason.isProgramStatus == false)
    #expect(withdrawn.currentDecision?.reason.isProgramStatus == false)
    state.cleanupAllAgentDetectionState()
  }
}
