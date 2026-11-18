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
    let state = makeSearchState(focusRequest: .restore)
    let field = makeField(owner: state)

    // SwiftUI can update the field before it adds the field to the window.
    field.takePendingFocus(for: .restore)
    #expect(state.searchFocusRequest == .restore)

    window.contentView?.addSubview(field)

    #expect(window.firstResponder === field.currentEditor())
    #expect(state.searchFocusRequest == nil)
  }

  @Test func appliedFocusRequestDoesNotTakeFocusBack() throws {
    let window = makeWindow()
    let state = makeSearchState(focusRequest: .restore)
    let field = makeField(owner: state)
    window.contentView?.addSubview(field)
    let other = NSTextField(frame: NSRect(x: 0, y: 60, width: 180, height: 24))
    window.contentView?.addSubview(other)
    try #require(window.makeFirstResponder(other))

    field.takePendingFocus(for: .restore)

    #expect(window.firstResponder === other.currentEditor())
  }

  @Test func newFocusRequestTakesFocusAgain() throws {
    let window = makeWindow()
    let state = makeSearchState(focusRequest: nil)
    let field = makeField(owner: state)
    window.contentView?.addSubview(field)
    let other = NSTextField(frame: NSRect(x: 0, y: 60, width: 180, height: 24))
    window.contentView?.addSubview(other)
    try #require(window.makeFirstResponder(other))

    state.transitionSearchFocus(.restoreRequested)
    field.takePendingFocus(for: .restore)

    #expect(window.firstResponder === field.currentEditor())
    #expect(state.searchFocusRequest == nil)
  }

  @Test func focusRequestChangedDuringFocusAcquisitionIsNotConsumed() throws {
    let window = SearchFocusRequestChangingWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled], backing: .buffered, defer: true
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let state = makeSearchState(focusRequest: nil)
    state.searchNeedle = "needle"
    let field = makeField(owner: state)
    field.stringValue = "needle"
    window.contentView?.addSubview(field)
    let other = NSTextField(frame: NSRect(x: 0, y: 60, width: 180, height: 24))
    window.contentView?.addSubview(other)
    try #require(window.makeFirstResponder(other))

    state.transitionSearchFocus(.restoreRequested)
    window.onMakeFirstResponder = { state.transitionSearchFocus(.findRequested) }
    field.takePendingFocus(for: .restore)

    #expect(window.firstResponder === field.currentEditor())
    #expect(state.searchFocusRequest == .find)

    field.takePendingFocus(for: .find)
    #expect(state.searchFocusRequest == nil)
    let editor = try #require(field.currentEditor() as? NSTextView)
    #expect(editor.selectedRange() == NSRange(location: 0, length: 6))
  }

  @Test func pendingFocusMovesToAReplacementField() throws {
    let window = makeWindow()
    let state = makeSearchState(focusRequest: nil)
    let field = makeField(owner: state)
    window.contentView?.addSubview(field)
    try #require(window.makeFirstResponder(field))

    // Split zoom asks for focus, then SwiftUI replaces the Find bar.
    state.transitionSearchFocus(.restoreRequested)
    field.removeFromSuperview()
    try #require(window.firstResponder === window)
    let replacement = makeField(owner: state)
    window.contentView?.addSubview(replacement)

    #expect(window.firstResponder === replacement.currentEditor())
    #expect(state.searchFocusRequest == nil)
  }

  @Test func takingSearchFocusCancelsAnOlderTerminalRetry() async throws {
    let window = makeWindow()
    let clock = TestClock()
    let requests = GhosttySurfaceView.FocusRequests()
    let surface = makeSurface()
    GhosttySurfaceView.moveFocus(to: surface, clock: clock, requests: requests)
    await Task.megaYield()

    let state = makeSearchState(focusRequest: nil)
    let field = makeField(owner: state)
    window.contentView?.addSubview(field)
    state.transitionSearchFocus(.restoreRequested)
    field.takePendingFocus(for: .restore, requests: requests)
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

  @Test func searchFocusTransitionUsesCurrentStateAndEvent() {
    let state = makeSearchState(focusRequest: nil)

    state.transitionSearchFocus(.findRequested)
    #expect(state.searchFocusRequest == .find)

    state.transitionSearchFocus(.restoreRequested)
    #expect(state.searchFocusRequest == .find)
    state.transitionSearchFocus(.requestApplied(.restore))
    #expect(state.searchFocusRequest == .find)

    state.transitionSearchFocus(.requestApplied(.find))
    #expect(state.searchFocusRequest == nil)

    state.transitionSearchFocus(.restoreRequested)
    #expect(state.searchFocusRequest == .restore)
    state.transitionSearchFocus(.findRequested)
    #expect(state.searchFocusRequest == .find)

    state.transitionSearchFocus(.searchEnded)
    #expect(state.searchFocusRequest == nil)
    state.transitionSearchFocus(.requestApplied(.find))
    #expect(state.searchFocusRequest == nil)
  }

  @Test func startSearchRequestsFocusAndKeepsTheQuery() {
    let surface = makeSurface()
    let state = surface.bridge.state

    handle(GHOSTTY_ACTION_START_SEARCH, on: surface)
    #expect(state.searchNeedle == "")
    #expect(state.searchFocusRequest == .find)

    state.transitionSearchFocus(.requestApplied(.find))
    state.searchNeedle = "typed"
    handle(GHOSTTY_ACTION_START_SEARCH, on: surface)
    #expect(state.searchNeedle == "typed")
    #expect(state.searchFocusRequest == .find)

    handle(GHOSTTY_ACTION_END_SEARCH, on: surface)
    #expect(state.searchNeedle == nil)
    #expect(state.searchFocusRequest == nil)
  }

  @Test(arguments: ["needle", "A😀中éZ"], [false, true])
  func startSearchSelectsTheExistingQuery(query: String, returnFromAnotherField: Bool) throws {
    let window = makeWindow()
    defer { window.close() }
    let surface = makeSurface()
    let state = surface.bridge.state
    state.searchNeedle = query
    let field = makeField(owner: state)
    field.stringValue = query
    window.contentView?.addSubview(field)
    try #require(window.makeFirstResponder(field))

    for selection in [NSRange(location: 1, length: 0), NSRange(location: 1, length: 3)] {
      let editor = try #require(field.currentEditor() as? NSTextView)
      editor.string = query
      editor.setSelectedRange(selection)
      if returnFromAnotherField {
        let other = NSTextField(frame: NSRect(x: 0, y: 60, width: 180, height: 24))
        window.contentView?.addSubview(other)
        try #require(window.makeFirstResponder(other))
        try #require(field.currentEditor() == nil)
      }

      handle(GHOSTTY_ACTION_START_SEARCH, on: surface)
      field.takePendingFocus(for: .find)

      let result = try #require(field.currentEditor() as? NSTextView)
      #expect(window.firstResponder === result)
      #expect(result.string == query)
      #expect(result.selectedRange() == NSRange(location: 0, length: query.utf16.count))
      #expect(state.searchFocusRequest == nil)
      result.insertText("next", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(result.string == "next")
    }
  }

  @Test func findWithDivergentEditorTextDoesNotSelectAllOnALaterEdit() throws {
    let window = makeWindow()
    defer { window.close() }
    let state = makeSearchState(focusRequest: nil)
    state.searchNeedle = "query"
    let field = makeField(owner: state)
    field.stringValue = "query"
    window.contentView?.addSubview(field)
    try #require(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    let insertion = NSRange(location: NSNotFound, length: 0)
    editor.setSelectedRange(NSRange(location: 5, length: 0))
    editor.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: insertion)
    try #require(editor.hasMarkedText())
    try #require(editor.string == "queryx")

    state.transitionSearchFocus(.findRequested)
    field.takePendingFocus(for: .find)
    #expect(state.searchFocusRequest == nil)
    #expect(editor.hasMarkedText())

    editor.unmarkText()
    state.searchNeedle = editor.string
    field.takePendingFocus(for: .find)
    editor.insertText("y", replacementRange: insertion)
    #expect(editor.string == "queryxy")
  }

  @Test func pendingFindSelectsTheQueryAfterWindowAttachment() throws {
    let window = makeWindow()
    defer { window.close() }
    let surface = makeSurface()
    let state = surface.bridge.state
    state.searchNeedle = "needle"
    let field = makeField(owner: state)
    handle(GHOSTTY_ACTION_START_SEARCH, on: surface)

    field.takePendingFocus(for: .find)
    #expect(state.searchFocusRequest == .find)
    window.contentView?.addSubview(field)

    let editor = try #require(field.currentEditor() as? NSTextView)
    #expect(window.firstResponder === editor)
    #expect(state.searchFocusRequest == .find)
    field.stringValue = "needle"
    field.takePendingFocus(for: .find)

    #expect(editor.string == "needle")
    #expect(editor.selectedRange() == NSRange(location: 0, length: 6))
    #expect(state.searchFocusRequest == nil)
  }

  @Test func focusRestoreDoesNotSelectTheQueryAgain() throws {
    let window = makeWindow()
    defer { window.close() }
    let surface = makeSurface()
    let state = surface.bridge.state
    state.searchNeedle = "needle"
    let field = makeField(owner: state)
    field.stringValue = "needle"
    window.contentView?.addSubview(field)
    handle(GHOSTTY_ACTION_START_SEARCH, on: surface)
    field.takePendingFocus(for: .find)
    let editor = try #require(field.currentEditor() as? NSTextView)
    let selection = NSRange(location: 2, length: 2)
    editor.setSelectedRange(selection)

    field.takePendingFocus(for: .find)
    #expect(editor.selectedRange() == selection)

    state.transitionSearchFocus(.restoreRequested)
    field.takePendingFocus(for: .restore)
    #expect(editor.selectedRange() == selection)
    #expect(state.searchFocusRequest == nil)
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

  private func makeSearchState(focusRequest: GhosttySurfaceState.SearchFocusRequest?) -> GhosttySurfaceState {
    let state = GhosttySurfaceState()
    state.searchNeedle = ""
    switch focusRequest {
    case .find:
      state.transitionSearchFocus(.findRequested)
    case .restore:
      state.transitionSearchFocus(.restoreRequested)
    case nil:
      break
    }
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

@MainActor
private final class SearchFocusRequestChangingWindow: NSWindow {
  var onMakeFirstResponder: (() -> Void)?

  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
    let didMakeFirstResponder = super.makeFirstResponder(responder)
    onMakeFirstResponder?()
    return didMakeFirstResponder
  }
}
