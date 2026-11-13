import AppKit
import ConcurrencyExtras
import GhosttyKit
import SwiftUI
import Testing

@testable import Prowl

@MainActor
@Suite(.serialized)
struct GhosttySurfaceSearchOverlayTests {
  @Test func searchInputSurvivesOverlayRebuild() async throws {
    let fixture = SearchOverlayFixture()
    defer { fixture.window.close() }
    await fixture.settle()

    let originalField = try fixture.field()
    #expect(originalField.stringValue.isEmpty)
    try #require(fixture.window.makeFirstResponder(originalField))
    let editor = try #require(originalField.currentEditor() as? NSTextView)
    #expect(fixture.window.firstResponder === editor)
    editor.insertText("needle", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(editor.string == "needle")
    #expect(fixture.surfaceView.bridge.state.searchInput == "needle")

    fixture.rebuild()
    await fixture.settle()

    let rebuiltField = try fixture.field()
    #expect(rebuiltField !== originalField)
    #expect(rebuiltField.stringValue == "needle")
    #expect(fixture.surfaceView.bridge.state.searchInput == "needle")
  }

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

  @Test func anotherRuntimeDoesNotCancelPendingSearchFocus() async throws {
    let fixture = SearchOverlayFixture(requestFocus: true)
    defer { fixture.window.close() }
    fixture.hostingView.layoutSubtreeIfNeeded()
    let field = try fixture.field()
    let otherRuntime = GhosttyRuntime()
    let otherSurface = GhosttySurfaceView(
      runtime: otherRuntime, workingDirectory: nil, context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    let otherWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled], backing: .buffered, defer: true
    )
    otherWindow.isReleasedWhenClosed = false
    defer { otherWindow.close() }
    otherWindow.contentView?.addSubview(otherSurface)

    otherSurface.requestFocus()
    await fixture.settle()

    #expect(field.currentEditor() != nil)
    #expect(!fixture.surfaceView.bridge.state.searchFocusPending)
    #expect(otherWindow.firstResponder === otherSurface)
  }

  @Test func focusedSearchKeepsFocusAfterOverlayRebuild() async throws {
    let fixture = SearchOverlayFixture(requestFocus: true)
    defer { fixture.window.close() }
    await fixture.settle()
    let originalField = try fixture.field()
    let editor = try #require(originalField.currentEditor() as? NSTextView)
    editor.insertText("needle", replacementRange: NSRange(location: NSNotFound, length: 0))
    try #require(!fixture.surfaceView.bridge.state.searchFocusPending)

    fixture.rebuild()
    await fixture.settle()

    let rebuiltField = try fixture.field()
    #expect(rebuiltField !== originalField)
    let rebuiltEditor = try #require(rebuiltField.currentEditor() as? NSTextView)
    #expect(fixture.window.firstResponder === rebuiltEditor)
    #expect(rebuiltEditor.string == "needle")
    rebuiltEditor.insertText(" updated", replacementRange: NSRange(location: 6, length: 0))
    #expect(fixture.surfaceView.bridge.state.searchInput == "needle updated")
    #expect(!fixture.surfaceView.bridge.state.searchFocusPending)
  }

  @Test(arguments: [false, true])
  func unfocusedSearchDoesNotTakeFocusAfterOverlayRebuild(fromTerminal: Bool) async throws {
    let fixture = SearchOverlayFixture(requestFocus: true)
    defer { fixture.window.close() }
    await fixture.settle()
    let originalField = try fixture.field()
    try #require(originalField.currentEditor() != nil)
    let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
    fixture.window.contentView?.addSubview(other)
    let target: NSView = fromTerminal ? fixture.surfaceView : other
    try #require(fixture.window.makeFirstResponder(target))
    let responder = try #require(fixture.window.firstResponder)

    fixture.rebuild()
    await fixture.settle()

    let rebuiltField = try fixture.field()
    #expect(rebuiltField !== originalField)
    #expect(rebuiltField.currentEditor() == nil)
    #expect(fixture.window.firstResponder === responder)
    if !fromTerminal {
      #expect(other.currentEditor() === responder)
    }
    #expect(!fixture.surfaceView.bridge.state.searchFocusPending)
  }

  @Test func repeatedFindKeepsFocusWhenTheOverlayRebuildsBeforeTheRequestRuns() async throws {
    let fixture = SearchOverlayFixture(requestFocus: true)
    defer { fixture.window.close() }
    await fixture.settle()
    let originalField = try fixture.field()
    try #require(originalField.currentEditor() != nil)

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_START_SEARCH
    _ = fixture.surfaceView.bridge.handleAction(target: ghostty_target_s(), action: action)
    fixture.rebuild()
    await fixture.settle()

    let rebuiltField = try fixture.field()
    #expect(rebuiltField !== originalField)
    #expect(rebuiltField.currentEditor() != nil)
    #expect(!fixture.surfaceView.bridge.state.searchFocusPending)
  }

  @Test func focusedReplacementKeepsTheOriginalWindowContextWhenSurfaceIsDetached() async throws {
    let fixture = SearchOverlayFixture(requestFocus: true)
    defer { fixture.window.close() }
    await fixture.settle()
    try #require(try fixture.field().currentEditor() != nil)

    fixture.surfaceView.removeFromSuperview()
    fixture.rebuild()
    await fixture.settle()

    let request = try #require(
      fixture.surfaceView.runtime.focusRequests.searchRequest(for: fixture.surfaceView.bridge.state))
    #expect(request.context?.window === fixture.window)
  }

  @Test func manuallyFocusedSearchKeepsFocusAfterOverlayRebuild() async throws {
    let fixture = SearchOverlayFixture(requestFocus: true)
    defer { fixture.window.close() }
    await fixture.settle()
    let originalField = try fixture.field()
    fixture.surfaceView.requestFocus()
    await fixture.settle()
    try #require(fixture.window.firstResponder === fixture.surfaceView)
    try #require(fixture.window.makeFirstResponder(originalField))
    try #require(originalField.currentEditor() != nil)

    fixture.rebuild()
    await fixture.settle()

    let rebuiltField = try fixture.field()
    #expect(rebuiltField !== originalField)
    #expect(rebuiltField.currentEditor() != nil)
    #expect(!fixture.surfaceView.bridge.state.searchFocusPending)
  }

  @Test func newerTextFieldFocusCancelsRebuildFocusTransfer() async throws {
    let fixture = SearchOverlayFixture(requestFocus: true)
    defer { fixture.window.close() }
    await fixture.settle()
    let originalField = try fixture.field()
    try #require(originalField.currentEditor() != nil)
    let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
    fixture.window.contentView?.addSubview(other)

    fixture.rebuild()
    fixture.hostingView.layoutSubtreeIfNeeded()
    try #require(fixture.window.makeFirstResponder(other))
    let editor = try #require(other.currentEditor())
    await fixture.settle()

    let rebuiltField = try fixture.field()
    #expect(rebuiltField.currentEditor() == nil)
    #expect(other.currentEditor() === editor)
    #expect(fixture.window.firstResponder === editor)
    #expect(!fixture.surfaceView.bridge.state.searchFocusPending)
  }

  @Test func closingSearchCancelsRebuildFocusTransfer() async throws {
    let fixture = SearchOverlayFixture(requestFocus: true)
    defer { fixture.window.close() }
    await fixture.settle()
    let originalField = try fixture.field()
    try #require(originalField.currentEditor() != nil)

    fixture.rebuild()
    fixture.hostingView.layoutSubtreeIfNeeded()
    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_END_SEARCH
    _ = fixture.surfaceView.bridge.handleAction(target: ghostty_target_s(), action: action)
    await fixture.settle()

    #expect(fixture.surfaceView.bridge.state.searchNeedle == nil)
    #expect(!fixture.surfaceView.bridge.state.searchFocusPending)
  }

  @Test func newerTerminalFocusCancelsRebuildFocusTransfer() async throws {
    let fixture = SearchOverlayFixture(requestFocus: true)
    defer { fixture.window.close() }
    await fixture.settle()
    let originalField = try fixture.field()
    try #require(originalField.currentEditor() != nil)

    fixture.rebuild()
    fixture.hostingView.layoutSubtreeIfNeeded()
    fixture.surfaceView.requestFocus()
    await fixture.settle()

    let rebuiltField = try fixture.field()
    #expect(rebuiltField.currentEditor() == nil)
    #expect(fixture.window.firstResponder === fixture.surfaceView)
    #expect(!fixture.surfaceView.bridge.state.searchFocusPending)
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
