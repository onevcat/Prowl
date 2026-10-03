import AppKit
import GhosttyKit
import Testing

@testable import Prowl

@MainActor
struct CanvasViewedSurfaceTests {
  @Test func surfaceVisibilityTracksTheRenderedViewport() {
    let fixture = Fixture()

    #expect(fixture.state.isVisibleSurface(fixture.surface.id))

    fixture.surface.setFrameOrigin(NSPoint(x: 2_000, y: 2_000))
    #expect(!fixture.state.isVisibleSurface(fixture.surface.id))

    fixture.surface.setFrameOrigin(NSPoint(x: 20, y: 20))
    fixture.window.reportsVisible = false
    #expect(!fixture.state.isVisibleSurface(fixture.surface.id))
  }

  @Test func actualCanvasFocusDoesNotDependOnNormalModeSelectionOrWindowCache() {
    let fixture = Fixture()

    #expect(fixture.state.isViewedSurface(fixture.surface.id))
    #expect(!fixture.state.isViewingWorktree())
  }

  enum UnviewedCondition: CaseIterable {
    case inactiveWindow, occludedWindow, detached, hidden, hiddenAncestor
    case logicalFocusOnly, clearedFocus, otherPane, otherTab
  }

  @Test(arguments: UnviewedCondition.allCases)
  func canvasDoesNotTreatUnviewedSurfacesAsRead(condition: UnviewedCondition) {
    let fixture = Fixture()
    // Stale normal-mode flags must never override the live Canvas window.
    fixture.state.lastWindowIsKey = true
    fixture.state.lastWindowIsVisible = true
    fixture.state.isSelected = { true }

    switch condition {
    case .inactiveWindow: fixture.window.reportsKey = false
    case .occludedWindow: fixture.window.reportsVisible = false
    case .detached: fixture.surface.removeFromSuperview()
    case .hidden: fixture.surface.isHidden = true
    case .hiddenAncestor: fixture.window.contentView?.isHidden = true
    case .logicalFocusOnly: fixture.window.makeFirstResponder(nil)
    case .clearedFocus: fixture.surface.focused = false
    case .otherPane:
      fixture.state.focusedSurfaceIdByTab[fixture.tabID] = UUID()
    case .otherTab:
      let other = fixture.state.tabManager.createTab(title: "Other", icon: nil)
      fixture.state.tabManager.selectTab(other)
    }

    #expect(!fixture.state.isViewedSurface(fixture.surface.id))
  }

  @Test func becomingTheActualResponderCompletesTheViewingTransition() {
    let fixture = Fixture()
    fixture.window.makeFirstResponder(nil)
    fixture.surface.focused = true
    #expect(!fixture.state.isViewedSurface(fixture.surface.id))

    #expect(fixture.window.makeFirstResponder(fixture.surface))
    #expect(fixture.state.isViewedSurface(fixture.surface.id))

    fixture.window.reportsKey = false
    #expect(!fixture.state.isViewedSurface(fixture.surface.id))
    fixture.window.reportsKey = true
    #expect(fixture.state.isViewedSurface(fixture.surface.id))
  }

  @Test func leavingCanvasRestoresTheNormalViewingPolicy() {
    let fixture = Fixture()
    fixture.state.isCanvasManaged = false
    #expect(!fixture.state.isViewedSurface(fixture.surface.id))

    fixture.state.isSelected = { true }
    fixture.state.lastWindowIsKey = true
    fixture.state.lastWindowIsVisible = true
    #expect(fixture.state.isViewedSurface(fixture.surface.id))
  }

  @Test func offscreenFocusedCompletionRemainsUnreadUntilItReturns() async {
    let fixture = Fixture()
    fixture.surface.setFrameOrigin(NSPoint(x: 2000, y: 2000))
    #expect(fixture.window.firstResponder === fixture.surface)
    #expect(!fixture.surface.isHiddenOrHasHiddenAncestor)
    #expect(!fixture.surface.bounds.intersects(fixture.surface.visibleRect))
    #expect(!fixture.state.isViewedSurface(fixture.surface.id))
    fixture.state.surfaceAgentStates[fixture.surface.id] = PaneAgentState(
      detectedAgent: .claude, state: .working, seen: true
    )
    fixture.state.agentDetectionPresenceBySurface[fixture.surface.id] = AgentDetectionPresence(currentAgent: .claude)
    fixture.state.lastAgentScreenScanBySurface[fixture.surface.id] = WorktreeTerminalState.AgentScreenScan(
      agent: .claude, text: "", detection: AgentScreenDetection(state: .idle, reason: .legacyDetector)
    )

    #expect(await fixture.state.detectAgentState(for: fixture.surface, tabId: fixture.tabID))
    #expect(fixture.state.surfaceAgentStates[fixture.surface.id]?.displayState == .done)
    fixture.state.markAgentSeen(surfaceID: fixture.surface.id)
    #expect(fixture.state.surfaceAgentStates[fixture.surface.id]?.displayState == .done)

    fixture.surface.setFrameOrigin(NSPoint(x: 20, y: 20))
    #expect(fixture.window.firstResponder === fixture.surface)
    #expect(await fixture.state.detectAgentState(for: fixture.surface, tabId: fixture.tabID))
    #expect(fixture.state.surfaceAgentStates[fixture.surface.id]?.displayState == .idle)
  }

  @Test(arguments: [0.5, 1.0, 2.0])
  func scaledViewportRequiresIntersection(scale: Double) {
    let fixture = Fixture()
    let viewport = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    viewport.clipsToBounds = true
    viewport.bounds = NSRect(x: 0, y: 0, width: 600 / scale, height: 400 / scale)
    fixture.window.contentView?.addSubview(viewport)
    viewport.addSubview(fixture.surface)
    #expect(fixture.window.makeFirstResponder(fixture.surface))
    fixture.surface.focused = true

    fixture.surface.setFrameOrigin(NSPoint(x: viewport.bounds.maxX + 10, y: 20))
    #expect(!fixture.state.isViewedSurface(fixture.surface.id))

    fixture.surface.setFrameOrigin(NSPoint(x: viewport.bounds.maxX, y: 20))
    #expect(!fixture.state.isViewedSurface(fixture.surface.id))

    fixture.surface.setFrameOrigin(NSPoint(x: viewport.bounds.maxX - 20, y: 20))
    #expect(fixture.state.isViewedSurface(fixture.surface.id))

    fixture.surface.setFrameOrigin(NSPoint(x: 20, y: 20))
    #expect(fixture.state.isViewedSurface(fixture.surface.id))
  }

  @Test func zeroAreaSurfaceDoesNotCountAsViewed() {
    let fixture = Fixture()
    fixture.surface.setFrameSize(.zero)
    #expect(!fixture.state.isViewedSurface(fixture.surface.id))
  }

  @Test func logicalFocusAndInactiveWindowDoNotReadCompletion() async {
    let fixture = Fixture()
    fixture.state.surfaceAgentStates[fixture.surface.id] = PaneAgentState(
      detectedAgent: .claude, state: .idle, seen: false
    )
    fixture.state.agentDetectionPresenceBySurface[fixture.surface.id] = AgentDetectionPresence(currentAgent: .claude)
    fixture.state.lastAgentScreenScanBySurface[fixture.surface.id] = WorktreeTerminalState.AgentScreenScan(
      agent: .claude, text: "", detection: AgentScreenDetection(state: .idle, reason: .legacyDetector)
    )
    fixture.window.makeFirstResponder(nil)
    #expect(await fixture.state.detectAgentState(for: fixture.surface, tabId: fixture.tabID))
    #expect(fixture.state.surfaceAgentStates[fixture.surface.id]?.displayState == .done)

    #expect(fixture.window.makeFirstResponder(fixture.surface))
    fixture.window.reportsKey = false
    #expect(await fixture.state.detectAgentState(for: fixture.surface, tabId: fixture.tabID))
    #expect(fixture.state.surfaceAgentStates[fixture.surface.id]?.displayState == .done)

    fixture.window.reportsKey = true
    #expect(await fixture.state.detectAgentState(for: fixture.surface, tabId: fixture.tabID))
    #expect(fixture.state.surfaceAgentStates[fixture.surface.id]?.displayState == .idle)

    fixture.state.surfaceAgentStates[fixture.surface.id] = PaneAgentState(
      detectedAgent: .claude, state: .blocked, seen: false
    )
    fixture.state.markAgentSeen(surfaceID: fixture.surface.id)
    #expect(fixture.state.surfaceAgentStates[fixture.surface.id]?.displayState == .blocked)
  }

  private struct Fixture {
    let state: WorktreeTerminalState
    let surface: GhosttySurfaceView
    let window: CanvasTestWindow
    let tabID: TerminalTabID

    init() {
      let runtime = GhosttyRuntime()
      state = WorktreeTerminalState(
        runtime: runtime,
        worktree: Worktree(
          id: "/tmp/repo/canvas",
          name: "canvas",
          detail: "",
          workingDirectory: URL(fileURLWithPath: "/tmp/repo/canvas"),
          repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
        ),
        skipsSurfaceCreationForTesting: true
      )
      surface = GhosttySurfaceView(
        runtime: runtime,
        workingDirectory: nil,
        context: GHOSTTY_SURFACE_CONTEXT_TAB,
        skipsSurfaceCreationForTesting: true
      )
      tabID = state.tabManager.createTab(title: "Canvas", icon: nil)
      state.tabManager.selectTab(tabID)
      state.surfaces[surface.id] = surface
      state.trees[tabID] = SplitTree<GhosttySurfaceView>(view: surface)
      state.focusedSurfaceIdByTab[tabID] = surface.id
      state.isCanvasManaged = true
      state.isSelected = { false }
      state.lastWindowIsKey = nil
      state.lastWindowIsVisible = nil

      window = CanvasTestWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled],
        backing: .buffered,
        defer: true
      )
      surface.frame = NSRect(x: 20, y: 20, width: 400, height: 300)
      window.contentView?.addSubview(surface)
      #expect(window.makeFirstResponder(surface))
      // No Ghostty C surface is created in these tests, so its focus callback is skipped.
      surface.focused = true
    }
  }
}

@MainActor
private final class CanvasTestWindow: NSWindow {
  var reportsKey = true
  var reportsVisible = true

  override var isKeyWindow: Bool { reportsKey }
  override var occlusionState: NSWindow.OcclusionState { reportsVisible ? [.visible] : [] }
}
