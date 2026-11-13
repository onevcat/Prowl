import AppKit
import ConcurrencyExtras
import GhosttyKit
import SwiftUI
import Testing

@testable import Prowl

@MainActor
@Suite(.serialized)
struct GhosttySurfaceSearchOverlayTests {
  @Test func manualSearchFocusReportsTheActiveSurface() async throws {
    let fixture = SearchOverlayFixture()
    defer { fixture.window.close() }
    await fixture.settle()
    let field = try fixture.field()
    var reportedFocus = false
    fixture.surfaceView.onFocusChange = { focused in reportedFocus = focused }

    try #require(fixture.window.makeFirstResponder(field))
    try #require(field.currentEditor() != nil)

    #expect(reportedFocus)
  }
}

@MainActor
private final class SearchOverlayFixture {
  let surfaceView: GhosttySurfaceView
  let window: NSWindow
  let hostingView: NSHostingView<SearchOverlayTestHost>
  private let shortcuts: GhosttyShortcutManager
  private var revision = 0

  init(requestFocus: Bool = false) {
    let runtime = GhosttyRuntime()
    shortcuts = GhosttyShortcutManager(runtime: runtime)
    surfaceView = GhosttySurfaceView(
      runtime: runtime, workingDirectory: nil, context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
    surfaceView.frame = content.bounds
    content.addSubview(surfaceView)
    window.contentView = content

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_START_SEARCH
    _ = surfaceView.bridge.handleAction(target: ghostty_target_s(), action: action)
    if !requestFocus {
      surfaceView.bridge.state.searchFocusPending = false
    }

    hostingView = NSHostingView(
      rootView: SearchOverlayTestHost(surfaceView: surfaceView, shortcuts: shortcuts, revision: 0)
    )
    hostingView.frame = content.bounds
    content.addSubview(hostingView)
  }

  func rebuild() {
    revision += 1
    hostingView.rootView = SearchOverlayTestHost(surfaceView: surfaceView, shortcuts: shortcuts, revision: revision)
  }

  func settle() async {
    for _ in 0..<5 {
      hostingView.layoutSubtreeIfNeeded()
      window.update()
      await Task.megaYield()
    }
  }

  func field() throws -> GhosttySearchField.SearchField {
    try #require(findSearchField(in: hostingView))
  }

  private func findSearchField(in view: NSView) -> GhosttySearchField.SearchField? {
    if let field = view as? GhosttySearchField.SearchField {
      return field
    }
    for subview in view.subviews {
      if let field = findSearchField(in: subview) {
        return field
      }
    }
    return nil
  }
}

private struct SearchOverlayTestHost: View {
  let surfaceView: GhosttySurfaceView
  let shortcuts: GhosttyShortcutManager
  let revision: Int

  var body: some View {
    GhosttySurfaceSearchOverlay(surfaceView: surfaceView)
      .id(revision)
      .environment(shortcuts)
      .environment(\.resolvedKeybindings, .appDefaults)
  }
}
