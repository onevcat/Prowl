import Foundation
import Testing

@testable import supacode

struct AgentScreenScanCacheTests {
  /// With no cache, the helper scans from scratch and returns a scan that
  /// round-trips the inputs and the freshly computed detection result.
  @Test func scansFromScratchWithoutCache() {
    let (detection, scan) = WorktreeTerminalState.resolveScreenDetection(
      agent: .claude,
      text: "screen",
      cache: nil
    )

    #expect(detection == DetectedAgent.claude.detectScreen(in: "screen"))
    #expect(
      scan
        == WorktreeTerminalState.AgentScreenScan(
          agent: .claude,
          text: "screen",
          detection: detection
        )
    )
  }

  /// When the cached agent and text both match, the helper returns the complete
  /// cached result without recomputing. A sentinel rule ID proves the reason,
  /// not only the raw state, survives the cache hit.
  @Test func reusesCachedDetectionWhenAgentAndTextMatch() {
    let text = ""
    let sentinel = AgentScreenDetection(
      state: .blocked,
      reason: .matched(AgentScreenRuleID("test.sentinel"))
    )
    let cachedScan = WorktreeTerminalState.AgentScreenScan(
      agent: .claude,
      text: text,
      detection: sentinel
    )
    #expect(DetectedAgent.claude.detectScreen(in: text) != sentinel)

    let (detection, scan) = WorktreeTerminalState.resolveScreenDetection(
      agent: .claude,
      text: text,
      cache: cachedScan
    )

    #expect(detection == sentinel)
    #expect(scan == cachedScan)
  }

  /// A changed screen invalidates the cache and forces a rescan.
  @Test func rescansWhenTextChanges() {
    let cachedScan = WorktreeTerminalState.AgentScreenScan(
      agent: .claude,
      text: "old",
      detection: AgentScreenDetection(state: .blocked, reason: .legacyDetector)
    )

    let (detection, scan) = WorktreeTerminalState.resolveScreenDetection(
      agent: .claude,
      text: "new",
      cache: cachedScan
    )

    #expect(detection == DetectedAgent.claude.detectScreen(in: "new"))
    #expect(scan.text == "new")
  }

  @Test func screenMotionRequiresAPriorScanFromTheSameDetectedAgent() {
    let cachedScan = WorktreeTerminalState.AgentScreenScan(
      agent: .codex,
      text: "old",
      detection: AgentScreenDetection(state: .working, reason: .legacyDetector)
    )

    #expect(
      WorktreeTerminalState.activeScreenChanged(
        agent: .codex,
        text: "new",
        previousAgent: .codex,
        cache: cachedScan
      )
    )
    #expect(
      !WorktreeTerminalState.activeScreenChanged(
        agent: .codex,
        text: "old",
        previousAgent: .codex,
        cache: cachedScan
      )
    )
    #expect(
      !WorktreeTerminalState.activeScreenChanged(
        agent: .codex,
        text: "new",
        previousAgent: .claude,
        cache: cachedScan
      )
    )
    #expect(
      !WorktreeTerminalState.activeScreenChanged(
        agent: .codex,
        text: "new",
        previousAgent: .codex,
        cache: nil
      )
    )
  }

  @MainActor
  @Test func exitingAgentClearsCachedScreenDetection() {
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: Worktree(
        id: "/tmp/repo/wt-1",
        name: "wt-1",
        detail: "",
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
        repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
      )
    )
    let surfaceID = UUID()
    state.surfaceAgentStates[surfaceID] = PaneAgentState(detectedAgent: .codex)
    state.lastAgentScreenScanBySurface[surfaceID] = WorktreeTerminalState.AgentScreenScan(
      agent: .codex,
      text: "screen",
      detection: AgentScreenDetection(state: .working, reason: .legacyDetector)
    )

    state.removeAgentEntryIfNeeded(surfaceID: surfaceID)

    #expect(state.lastAgentScreenScanBySurface[surfaceID] == nil)
  }

  /// A different detected agent invalidates the cache even when the text is
  /// identical, since screen detections are agent-specific.
  @Test func rescansWhenAgentChanges() {
    let cachedScan = WorktreeTerminalState.AgentScreenScan(
      agent: .codex,
      text: "screen",
      detection: AgentScreenDetection(state: .blocked, reason: .legacyDetector)
    )

    let (detection, scan) = WorktreeTerminalState.resolveScreenDetection(
      agent: .claude,
      text: "screen",
      cache: cachedScan
    )

    #expect(detection == DetectedAgent.claude.detectScreen(in: "screen"))
    #expect(scan.agent == .claude)
  }
}
