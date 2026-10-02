import Testing

@testable import supacode

struct WindowSurfacingTests {
  @Test func mainWindowCandidateIgnoresUntaggedHelperWindows() {
    let snapshots = [
      MainWindowSurface.Snapshot(identifier: nil, isVisible: true),
      MainWindowSurface.Snapshot(identifier: "auxiliary", isVisible: true),
    ]

    #expect(MainWindowSurface.mainWindowIndex(in: snapshots) == nil)
  }

  @Test func mainWindowCandidateReturnsTaggedMainWindowIndex() {
    let snapshots = [
      MainWindowSurface.Snapshot(identifier: nil, isVisible: true),
      MainWindowSurface.Snapshot(identifier: WindowID.main, isVisible: false),
    ]

    #expect(MainWindowSurface.mainWindowIndex(in: snapshots) == 1)
  }

  @Test func visibleMainWindowDetectionRequiresMainIdentifier() {
    #expect(
      MainWindowSurface.hasVisibleMainWindow(
        in: [MainWindowSurface.Snapshot(identifier: nil, isVisible: true)]
      ) == false
    )
    #expect(
      MainWindowSurface.hasVisibleMainWindow(
        in: [MainWindowSurface.Snapshot(identifier: WindowID.main, isVisible: false)]
      ) == false
    )
    #expect(
      MainWindowSurface.hasVisibleMainWindow(
        in: [MainWindowSurface.Snapshot(identifier: WindowID.main, isVisible: true)]
      ) == true
    )
  }

  @Test func windowCountsSeparateMainAndVisibleWindows() {
    let snapshots = [
      MainWindowSurface.Snapshot(identifier: nil, isVisible: true),
      MainWindowSurface.Snapshot(identifier: "auxiliary", isVisible: true),
      MainWindowSurface.Snapshot(identifier: WindowID.main, isVisible: false),
      MainWindowSurface.Snapshot(identifier: WindowID.main, isVisible: true),
    ]

    #expect(MainWindowSurface.mainWindowCount(in: snapshots) == 2)
    #expect(MainWindowSurface.visibleMainWindowCount(in: snapshots) == 1)
    #expect(MainWindowSurface.visibleWindowCount(in: snapshots) == 3)
  }

  @MainActor
  @Test func windowlessStallReportRequiresActiveAppWithoutVisibleMainWindow() {
    #expect(
      WindowLifecycleDiagnostics.windowlessStallReportDecision(
        appIsActive: false,
        snapshots: []
      ) == .suppress
    )
    #expect(
      WindowLifecycleDiagnostics.windowlessStallReportDecision(
        appIsActive: true,
        snapshots: [MainWindowSurface.Snapshot(identifier: WindowID.main, isVisible: true)]
      ) == .resolveVisibleMainWindow
    )
    #expect(
      WindowLifecycleDiagnostics.windowlessStallReportDecision(
        appIsActive: true,
        snapshots: [MainWindowSurface.Snapshot(identifier: WindowID.main, isVisible: false)]
      ) == .report
    )
  }

  @MainActor
  @Test func windowlessTimeoutReportResolvesVisibleMainWindowBeforeReporting() {
    #expect(
      WindowLifecycleDiagnostics.windowlessTimeoutReportDecision(
        appIsActive: true,
        windowlessContext: "surfaceMainWindow(openWindowRequested)",
        snapshots: [MainWindowSurface.Snapshot(identifier: WindowID.main, isVisible: true)]
      ) == .resolveVisibleMainWindow
    )
    #expect(
      WindowLifecycleDiagnostics.windowlessTimeoutReportDecision(
        appIsActive: false,
        windowlessContext: "launch",
        snapshots: []
      ) == .suppress
    )
    #expect(
      WindowLifecycleDiagnostics.windowlessTimeoutReportDecision(
        appIsActive: true,
        windowlessContext: "surfaceMainWindow(openWindowRequested)",
        snapshots: [MainWindowSurface.Snapshot(identifier: WindowID.main, isVisible: false)]
      ) == .report
    )
  }
}
