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
    let request = AgentProfileLaunchRequest(
      plan: plan,
      placement: .tab(background: false)
    )

    let result = state.launchAgentProfile(request)

    #expect(result == .failure(.homeProvisioningFailed))
    #expect(state.tabManager.tabs.isEmpty)
    #expect(state.launchProfilesBySurface.isEmpty)
  }

  @Test func explicitAnchorWinsOverCurrentSelectionAndReturnsBothIdentities() throws {
    let state = makeState()
    let anchor = try state.launchAgentProfile(
      AgentProfileLaunchRequest(
        plan: makePlan(dedicatedHome: nil),
        placement: .tab(background: false)
      )
    ).get()
    let selected = try state.launchAgentProfile(
      AgentProfileLaunchRequest(
        plan: makePlan(dedicatedHome: nil),
        placement: .tab(background: false)
      )
    ).get()
    #expect(state.tabManager.selectedTabId == selected.tabID)

    let launched = try state.launchAgentProfile(
      AgentProfileLaunchRequest(
        plan: makePlan(dedicatedHome: nil, runtime: .claude),
        placement: .split(anchor: anchor.surfaceID, direction: .left, background: false)
      )
    ).get()

    #expect(launched.tabID == anchor.tabID)
    #expect(launched.surfaceID != anchor.surfaceID)
    #expect(state.tabID(containing: launched.surfaceID) == anchor.tabID)
    #expect(state.focusedSurfaceId(in: anchor.tabID) == launched.surfaceID)
    #expect(state.launchProfilesBySurface[launched.surfaceID]?.runtime == .claude)
  }

  @Test func requestPlacementOverridesTheProfilePlan() throws {
    let state = makeState()
    let anchor = try state.launchAgentProfile(
      AgentProfileLaunchRequest(
        plan: makePlan(dedicatedHome: nil),
        placement: .tab(background: false)
      )
    ).get()
    let plan = makePlan(dedicatedHome: nil, runtime: .claude, placement: .tab)

    let launched = try state.launchAgentProfile(
      AgentProfileLaunchRequest(
        plan: plan,
        placement: .split(anchor: anchor.surfaceID, direction: .down, background: false)
      )
    ).get()

    #expect(state.tabManager.tabs.count == 1)
    #expect(launched.tabID == anchor.tabID)
    #expect(state.tabID(containing: launched.surfaceID) == anchor.tabID)
  }

  @Test func backgroundTabPreservesTheSelectedTabAndFocusedSurface() throws {
    let state = makeState()
    let foreground = try state.launchAgentProfile(
      AgentProfileLaunchRequest(
        plan: makePlan(dedicatedHome: nil),
        placement: .tab(background: false)
      )
    ).get()

    let background = try state.launchAgentProfile(
      AgentProfileLaunchRequest(
        plan: makePlan(dedicatedHome: nil, runtime: .claude),
        placement: .tab(background: true)
      )
    ).get()

    #expect(background.tabID != foreground.tabID)
    #expect(background.surfaceID != foreground.surfaceID)
    #expect(state.tabManager.selectedTabId == foreground.tabID)
    #expect(state.currentFocusedSurfaceId() == foreground.surfaceID)
    #expect(state.tabID(containing: background.surfaceID) == background.tabID)
  }

  @Test func backgroundSplitPreservesTheAnchorFocus() throws {
    let state = makeState()
    let anchor = try state.launchAgentProfile(
      AgentProfileLaunchRequest(
        plan: makePlan(dedicatedHome: nil),
        placement: .tab(background: false)
      )
    ).get()

    let background = try state.launchAgentProfile(
      AgentProfileLaunchRequest(
        plan: makePlan(dedicatedHome: nil, runtime: .claude),
        placement: .split(anchor: anchor.surfaceID, direction: .right, background: true)
      )
    ).get()

    #expect(background.tabID == anchor.tabID)
    #expect(state.focusedSurfaceId(in: anchor.tabID) == anchor.surfaceID)
    #expect(state.currentFocusedSurfaceId() == anchor.surfaceID)
  }

  @Test func frozenDynamicProfileContextRejectsFocusAndInheritedCWDDrift() throws {
    let state = makeState()
    let first = try state.launchAgentProfile(
      AgentProfileLaunchRequest(
        plan: makePlan(dedicatedHome: nil),
        placement: .tab(background: false)
      )
    ).get()
    _ = try state.launchAgentProfile(
      AgentProfileLaunchRequest(
        plan: makePlan(dedicatedHome: nil),
        placement: .tab(background: false)
      )
    ).get()
    let request = AgentProfileLaunchRequest(
      plan: makePlan(dedicatedHome: nil),
      placement: .tab(background: false)
    )
    let frozen = try state.freezeAgentProfileLaunchContext(request).get()
    #expect(state.isAgentProfileLaunchContextValid(frozen))

    #expect(state.focusSurface(id: first.surfaceID))
    #expect(!state.isAgentProfileLaunchContextValid(frozen))
    let cwdOnly = FrozenAgentProfileLaunchContext(
      request: frozen.request,
      inheritedCWD: frozen.inheritedCWD,
      anchorSurfaceID: frozen.anchorSurfaceID,
      tracksFocusedAnchor: false,
      tracksInheritedCWD: true
    )
    #expect(
      !state.isAgentProfileLaunchContextValid(
        cwdOnly,
        inheritedCWDOverride: URL(filePath: "/tmp/repo/changed", directoryHint: .isDirectory)
      )
    )
  }

  @Test func explicitSplitFailureDoesNotFallBackToATab() {
    let state = makeState()
    let missingAnchor = UUID()

    let result = state.launchAgentProfile(
      AgentProfileLaunchRequest(
        plan: makePlan(dedicatedHome: nil, placement: .split),
        placement: .split(anchor: missingAnchor, direction: .right, background: false)
      )
    )

    #expect(result == .failure(.splitCreationFailed(.anchorNotFound(missingAnchor))))
    #expect(state.tabManager.tabs.isEmpty)
  }

  @Test func compatibilityWrapperKeepsSplitToTabFallback() throws {
    let state = makeState()

    let surfaceID = try #require(
      state.launchAgentProfile(
        makePlan(dedicatedHome: nil, placement: .split)
      )
    )

    #expect(state.tabManager.tabs.count == 1)
    #expect(state.tabID(containing: surfaceID) == state.tabManager.tabs.first?.id)
  }

  @Test func surfaceIsInstalledAndRegisteredBeforeProfileInputIsArmed() throws {
    let state = makeState()
    var callbackSurfaceID: UUID?
    var callbackObservedInstalledSurface = false
    var callbackObservedUnarmedSurface = false
    state.onAgentProfileSurfacePrepared = { surfaceID, _ in
      callbackSurfaceID = surfaceID
      callbackObservedInstalledSurface =
        state.surfaceView(for: surfaceID) != nil
        && state.launchProfilesBySurface[surfaceID] != nil
      callbackObservedUnarmedSurface = state.surfaceView(for: surfaceID)?.surfaceCreationArmed == false
      return true
    }

    let launched = try state.launchAgentProfile(
      AgentProfileLaunchRequest(
        plan: makePlan(dedicatedHome: nil),
        placement: .tab(background: false)
      )
    ).get()

    #expect(callbackSurfaceID == launched.surfaceID)
    #expect(callbackObservedInstalledSurface)
    #expect(callbackObservedUnarmedSurface)
    #expect(state.surfaceView(for: launched.surfaceID)?.surfaceCreationArmed == true)
  }

  @Test func deferredProfileAppliesFontSizeAdjustmentAfterSurfaceCreation() throws {
    let state = makeState(
      skipsSurfaceCreationForTesting: false,
      defaultFontSize: 18
    )
    defer { state.cleanupAllAgentDetectionState() }

    let launched = try state.launchAgentProfile(
      AgentProfileLaunchRequest(
        plan: makePlan(dedicatedHome: nil),
        placement: .tab(background: false)
      )
    ).get()

    let view = try #require(state.surfaceView(for: launched.surfaceID))
    #expect(view.didApplyFontSizeAdjustmentMarker)
  }

  @Test func deferredGhosttyCreationFailureRollsBackRegistrationAndSurface() {
    let state = makeState(
      skipsSurfaceCreationForTesting: false,
      failsSurfaceCreationForTesting: true
    )
    var registeredSurface: UUID?
    var closedSurface: UUID?
    state.onAgentProfileSurfacePrepared = { surfaceID, _ in
      registeredSurface = surfaceID
      return true
    }
    state.onSurfaceClosed = { closedSurface = $0 }

    let result = state.launchAgentProfile(
      AgentProfileLaunchRequest(
        plan: makePlan(dedicatedHome: nil),
        placement: .tab(background: false)
      )
    )

    #expect(result == .failure(.surfaceCreationFailed))
    #expect(closedSurface == registeredSurface)
    #expect(state.tabManager.tabs.isEmpty)
    #expect(state.surfaces.isEmpty)
    #expect(state.launchProfilesBySurface.isEmpty)
  }

  @Test func registrationFailureRollsBackBeforeLeavingALiveSurface() {
    let state = makeState()
    state.onAgentProfileSurfacePrepared = { _, _ in false }

    let result = state.launchAgentProfile(
      AgentProfileLaunchRequest(
        plan: makePlan(dedicatedHome: nil),
        placement: .tab(background: false)
      )
    )

    #expect(result == .failure(.hookRegistrationFailed))
    #expect(state.tabManager.tabs.isEmpty)
    #expect(state.surfaces.isEmpty)
    #expect(state.launchProfilesBySurface.isEmpty)
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

  @Test func launchTabWearsTheRuntimeIconInsteadOfTheTerminalGlyph() {
    // No runtime falls back to the generic glyph: a new case added without a
    // `CommandIconMap` entry would otherwise launch unbranded and silently.
    for runtime in AgentProfileRuntime.allCases {
      #expect(WorktreeTerminalState.launchTabIcon(for: runtime) != nil, "\(runtime) has no icon")
    }
    #expect(WorktreeTerminalState.launchTabIcon(for: .claude)?.storageString != "terminal")
    #expect(WorktreeTerminalState.launchTabIcon(for: .codex)?.storageString != "terminal")
    #expect(
      WorktreeTerminalState.launchTabIcon(for: .claude)?.storageString
        != WorktreeTerminalState.launchTabIcon(for: .codex)?.storageString
    )
  }

  @Test func launchCreatesTheTabWithTheRuntimeIcon() {
    let state = makeState()

    _ = state.launchAgentProfile(makePlan(dedicatedHome: nil))

    // Guards the call site, not just the helper: a hardcoded glyph here is the
    // original bug, and it survives a helper-only assertion.
    #expect(state.tabManager.tabs.count == 1)
    #expect(
      state.tabManager.tabs.first?.icon
        == WorktreeTerminalState.launchTabIcon(for: .codex)?.storageString
    )
    #expect(state.tabManager.tabs.first?.icon != "terminal")
    // Left claimable, so a later command in the same tab still wins the slot.
    #expect(state.tabManager.tabs.first?.iconLock == .auto)
  }

  @Test func splitLaunchRebrandsTheContainingTab() throws {
    let state = makeState()
    _ = state.launchAgentProfile(makePlan(dedicatedHome: nil))
    let tabID = try #require(state.tabManager.tabs.first?.id)
    state.tabManager.updateIcon(tabID, icon: "@asset:Git")

    let surfaceID = state.launchAgentProfile(
      makePlan(dedicatedHome: nil, runtime: .claude, placement: .split)
    )

    // The split becomes the focused surface, so its runtime owns the tab icon;
    // its `env …` title never reaches `CommandIconMap`.
    #expect(state.tabID(containing: try #require(surfaceID)) == tabID)
    #expect(state.tabManager.tabs.count == 1)
    #expect(
      state.tabManager.tabs.first?.icon
        == WorktreeTerminalState.launchTabIcon(for: .claude)?.storageString
    )
    #expect(state.tabManager.tabs.first?.iconLock == .auto)
  }

  @Test func splitLaunchLeavesAClaimedIconAlone() throws {
    let state = makeState()
    _ = state.launchAgentProfile(makePlan(dedicatedHome: nil))
    let tabID = try #require(state.tabManager.tabs.first?.id)
    state.tabManager.overrideIcon(tabID, icon: "@asset:Git")

    _ = state.launchAgentProfile(
      makePlan(dedicatedHome: nil, runtime: .claude, placement: .split)
    )

    #expect(state.tabManager.tabs.first?.icon == "@asset:Git")
    #expect(state.tabManager.tabs.first?.iconLock == .user)
  }

  @Test func splitLaunchLeavesAScriptIconAlone() throws {
    let state = makeState()
    _ = state.launchAgentProfile(makePlan(dedicatedHome: nil))
    let tabID = try #require(state.tabManager.tabs.first?.id)
    state.tabManager.setScriptIcon(tabID, icon: "@asset:Git")

    _ = state.launchAgentProfile(
      makePlan(dedicatedHome: nil, runtime: .claude, placement: .split)
    )

    // A launch is auto-detection's peer, not a script: it yields to `.script`
    // just as `CommandIconMap` does.
    #expect(state.tabManager.tabs.first?.icon == "@asset:Git")
    #expect(state.tabManager.tabs.first?.iconLock == .script)
  }

  private func makeState(
    skipsSurfaceCreationForTesting: Bool = true,
    failsSurfaceCreationForTesting: Bool = false,
    defaultFontSize: Float32? = nil
  ) -> WorktreeTerminalState {
    WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: Worktree(
        id: "/tmp/repo/wt-1",
        name: "wt-1",
        detail: "",
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
        repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
      ),
      defaultFontSize: defaultFontSize,
      skipsSurfaceCreationForTesting: skipsSurfaceCreationForTesting,
      failsSurfaceCreationForTesting: failsSurfaceCreationForTesting
    )
  }

  private func makePlan(
    dedicatedHome: URL?,
    runtime: AgentProfileRuntime = .codex,
    placement: AgentProfilePlacement = .tab
  ) -> AgentProfileLaunchPlan {
    AgentProfileLaunchPlan(
      profileID: UUID(),
      profileName: "Codex · Bound",
      runtime: runtime,
      invocation: AgentInvocation(executable: runtime.agent.iconLookupToken, arguments: []),
      commandEnvironmentTokens: [],
      placement: placement,
      splitDirection: .right,
      surfaceEnvironment: [:],
      dedicatedHome: dedicatedHome
    )
  }
}
