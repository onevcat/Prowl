import Foundation
import Testing

@testable import supacode

/// Terminal-layer behavior of `launchAgentProfile` that is testable without a
/// live Ghostty surface (docs-ai 053/005).
@MainActor
struct WorktreeTerminalStateAgentProfileTests {
  @Test func provisionFailureAbortsTheLaunchEntirely() {
    let state = makeState()
    // A dedicated home outside the profile-home base fails the containment
    // gate before any surface is created.
    let plan = makePlan(
      dedicatedHome: URL(filePath: "/tmp/prowl-test-outside-base/home", directoryHint: .isDirectory)
    )

    let surfaceID = state.launchAgentProfile(plan)

    #expect(surfaceID == nil)
    #expect(state.tabManager.tabs.isEmpty)
    #expect(state.launchProfilesBySurface.isEmpty)
  }

  @Test func handoffLaunchCreatesAnUnselectedTabAtTheRequestedRoot() throws {
    let state = makeState()
    let originalTabID = try #require(state.createTab())
    let originalSurfaceID = try #require(state.focusedSurfaceId(in: originalTabID))
    let profileID = UUID()
    let root = URL(fileURLWithPath: "/tmp/repo/handoff-root", isDirectory: true)
    let plan = makePlan(
      dedicatedHome: nil,
      profileID: profileID,
      placement: .split,
      surfaceEnvironment: ["PROWL_ENV_API_KEY": "secret"]
    )
    defer { state.closeAllSurfaces() }

    let result = try #require(
      state.launchAgentProfile(plan, context: .handoffBackgroundTab(root: root))
    )

    #expect(state.tabManager.tabs.count == 2)
    #expect(state.tabManager.selectedTabId == originalTabID)
    #expect(state.focusedSurfaceId(in: originalTabID) == originalSurfaceID)
    #expect(result.tabID != originalTabID)
    #expect(state.tabID(containing: result.surfaceID) == result.tabID)
    #expect(result.paneTitle == plan.profileName)
    #expect(state.surfaceView(for: result.surfaceID)?.launchWorkingDirectory == root)
    #expect(
      state.launchProfilesBySurface[result.surfaceID]
        == WorktreeTerminalState.SurfaceLaunchProfile(
          profileID: profileID,
          name: plan.profileName,
          runtime: plan.runtime,
          dedicatedHome: nil
        )
    )
  }

  @Test func launchProfileNameOnlyAppliesToTheLaunchedRuntime() {
    let state = makeState()
    let surfaceID = UUID()
    state.launchProfilesBySurface[surfaceID] = WorktreeTerminalState.SurfaceLaunchProfile(
      profileID: UUID(),
      name: "Codex · Work",
      runtime: .codex,
      dedicatedHome: nil
    )

    #expect(state.launchProfileName(surfaceID: surfaceID, detected: .codex) == "Codex · Work")
    // A *different* agent started manually in the same pane must not wear the
    // old profile's name — same gating rule as `configRoot(forDetected:)`.
    #expect(state.launchProfileName(surfaceID: surfaceID, detected: .claude) == nil)
    #expect(state.launchProfileName(surfaceID: UUID(), detected: .codex) == nil)
  }

  @Test func launchIdentityClearsWhenTheLaunchedAgentExits() {
    let state = makeState()
    let surfaceID = UUID()
    state.launchProfilesBySurface[surfaceID] = WorktreeTerminalState.SurfaceLaunchProfile(
      profileID: UUID(),
      name: "Codex · Work",
      runtime: .codex,
      dedicatedHome: nil
    )
    state.surfaceAgentStates[surfaceID] = PaneAgentState(detectedAgent: .codex)

    state.removeAgentEntryIfNeeded(surfaceID: surfaceID)

    // The identity lives exactly as long as the launched agent: a manually
    // started agent afterwards is the user's own (docs-ai 053/006).
    #expect(state.launchProfilesBySurface[surfaceID] == nil)
  }

  private func makeState() -> WorktreeTerminalState {
    WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: Worktree(
        id: "/tmp/repo/wt-1",
        name: "wt-1",
        detail: "",
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
        repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
      )
    )
  }

  private func makePlan(
    dedicatedHome: URL?,
    profileID: UUID = UUID(),
    placement: AgentProfilePlacement = .tab,
    surfaceEnvironment: [String: String] = [:]
  ) -> AgentProfileLaunchPlan {
    AgentProfileLaunchPlan(
      profileID: profileID,
      profileName: "Codex · Bound",
      runtime: .codex,
      invocation: AgentInvocation(executable: "codex", arguments: []),
      commandEnvironmentTokens: [],
      placement: placement,
      splitDirection: .right,
      surfaceEnvironment: surfaceEnvironment,
      dedicatedHome: dedicatedHome
    )
  }
}
