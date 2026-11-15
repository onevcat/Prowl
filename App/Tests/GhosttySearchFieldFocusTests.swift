import AppKit
import Clocks
import ConcurrencyExtras
import GhosttyKit
import Testing

@testable import Prowl

@MainActor
struct GhosttySearchFieldFocusTests {
  @Test func pendingFocusWaitsUntilTheFieldHasAWindow() throws {
    let window = makeWindow()
    let state = makeSearchState(focusPending: true)
    let field = makeField(owner: state)

    // SwiftUI can update the field before it adds the field to the window.
    field.takePendingFocus()
    #expect(state.searchFocusPending)

    window.contentView?.addSubview(field)

    #expect(window.firstResponder === field.currentEditor())
    #expect(!state.searchFocusPending)
  }

  @Test func appliedFocusRequestDoesNotTakeFocusBack() throws {
    let window = makeWindow()
    let state = makeSearchState(focusPending: true)
    let field = makeField(owner: state)
    window.contentView?.addSubview(field)
    let other = NSTextField(frame: NSRect(x: 0, y: 60, width: 180, height: 24))
    window.contentView?.addSubview(other)
    try #require(window.makeFirstResponder(other))

    field.takePendingFocus()

    #expect(window.firstResponder === other.currentEditor())
  }

  @Test func newFocusRequestTakesFocusAgain() throws {
    let window = makeWindow()
    let state = makeSearchState(focusPending: false)
    let field = makeField(owner: state)
    window.contentView?.addSubview(field)
    let other = NSTextField(frame: NSRect(x: 0, y: 60, width: 180, height: 24))
    window.contentView?.addSubview(other)
    try #require(window.makeFirstResponder(other))

    state.searchFocusPending = true
    field.takePendingFocus()

    #expect(window.firstResponder === field.currentEditor())
    #expect(!state.searchFocusPending)
  }

  @Test func pendingFocusMovesToAReplacementField() throws {
    let window = makeWindow()
    let state = makeSearchState(focusPending: false)
    let field = makeField(owner: state)
    window.contentView?.addSubview(field)
    try #require(window.makeFirstResponder(field))

    // Split zoom asks for focus, then SwiftUI replaces the Find bar.
    state.searchFocusPending = true
    field.removeFromSuperview()
    try #require(window.firstResponder === window)
    let replacement = makeField(owner: state)
    window.contentView?.addSubview(replacement)

    #expect(window.firstResponder === replacement.currentEditor())
    #expect(!state.searchFocusPending)
  }

  @Test func takingSearchFocusCancelsAnOlderTerminalRetry() async throws {
    let window = makeWindow()
    let clock = TestClock()
    let requests = GhosttySurfaceView.FocusRequests()
    let surface = makeSurface()
    GhosttySurfaceView.moveFocus(to: surface, clock: clock, requests: requests)
    await Task.megaYield()

    let state = makeSearchState(focusPending: false)
    let field = makeField(owner: state)
    window.contentView?.addSubview(field)
    state.searchFocusPending = true
    field.takePendingFocus(requests: requests)
    try #require(window.firstResponder === field.currentEditor())

    window.contentView?.addSubview(surface)
    await clock.advance(by: .seconds(2))
    await Task.megaYield()

    #expect(window.firstResponder === field.currentEditor())
  }

  @Test func surfaceReportsWhenItsSearchFieldHasFocus() throws {
    let window = makeWindow()
    let surface = makeSurface()
    let other = makeSurface()
    window.contentView?.addSubview(surface)
    window.contentView?.addSubview(other)
    surface.bridge.state.searchNeedle = ""
    let field = makeField(owner: surface.bridge.state)
    window.contentView?.addSubview(field)
    try #require(window.makeFirstResponder(field))

    #expect(surface.isSearchFieldFocused)
    #expect(!other.isSearchFieldFocused)

    try #require(window.makeFirstResponder(surface))
    #expect(!surface.isSearchFieldFocused)
  }

  @Test func startSearchRequestsFocusAndKeepsTheQuery() {
    let surface = makeSurface()
    let state = surface.bridge.state

    handle(GHOSTTY_ACTION_START_SEARCH, on: surface)
    #expect(state.searchNeedle == "")
    #expect(state.searchFocusPending)

    state.searchFocusPending = false
    state.searchNeedle = "typed"
    handle(GHOSTTY_ACTION_START_SEARCH, on: surface)
    #expect(state.searchNeedle == "typed")
    #expect(state.searchFocusPending)

    handle(GHOSTTY_ACTION_END_SEARCH, on: surface)
    #expect(state.searchNeedle == nil)
    #expect(!state.searchFocusPending)
  }

  private func handle(_ tag: ghostty_action_tag_e, on surface: GhosttySurfaceView) {
    var action = ghostty_action_s()
    action.tag = tag
    _ = surface.bridge.handleAction(target: ghostty_target_s(), action: action)
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled], backing: .buffered, defer: true
    )
    window.isReleasedWhenClosed = false
    return window
  }

  private func makeSearchState(focusPending: Bool) -> GhosttySurfaceState {
    let state = GhosttySurfaceState()
    state.searchNeedle = ""
    state.searchFocusPending = focusPending
    return state
  }

  private func makeField(owner: GhosttySurfaceState) -> GhosttySearchField.SearchField {
    let field = GhosttySearchField.SearchField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
    field.owner = owner
    return field
  }

  private func makeSurface() -> GhosttySurfaceView {
    GhosttySurfaceView(
      runtime: GhosttyRuntime(), workingDirectory: nil, fontSize: nil, context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
  }
}
