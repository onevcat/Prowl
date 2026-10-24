import AppKit
import GhosttyKit
import SwiftUI
import Testing

@testable import Prowl

@MainActor
struct TerminalSplitAXContainerViewTests {
  @Test func detachHostingViewRemovesTheSplitTreeHost() {
    let surface = GhosttySurfaceView(
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    let container = TerminalSplitAXContainerView()
    container.update(
      rootView: TerminalSplitTreeView(
        tree: SplitTree(view: surface),
        unfocusedSplitOverlay: (nil, 0),
        hasNotification: { _ in false },
        action: { _ in }
      ),
      panes: [surface]
    )
    #expect(container.subviews.contains { $0 is NSHostingView<TerminalSplitTreeView> })

    container.detachHostingView()

    #expect(container.subviews.isEmpty)
  }
}
