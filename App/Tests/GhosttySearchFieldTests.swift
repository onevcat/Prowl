import AppKit
import Clocks
import ConcurrencyExtras
import GhosttyKit
import SwiftUI
import Testing

@testable import Prowl

@MainActor
struct GhosttySearchFieldTests {
  @Test func missingSourceWindowCannotAuthorizeFocusAfterAttachment() async throws {
    let window = makeWindow()
    let source = makeSurface(runtime: GhosttyRuntime())
    startSearch(on: source)
    let other = NSTextField(frame: NSRect(x: 0, y: 40, width: 180, height: 24))
    window.contentView?.addSubview(other)
    try #require(window.makeFirstResponder(other))
    let editor = try #require(other.currentEditor())
    window.contentView?.addSubview(source)
    let field = makeField(for: source)
    window.contentView?.addSubview(field)
    await Task.megaYield()

    #expect(other.currentEditor() === editor)
    #expect(window.firstResponder === editor)
    #expect(field.currentEditor() == nil)
    #expect(!source.bridge.state.searchFocusPending)
  }

  @Test(arguments: [false, true])
  func pendingFindSurvivesSourceDetachment(reattach: Bool) async throws {
    let window = makeWindow()
    let source = makeSurface(runtime: GhosttyRuntime())
    window.contentView?.addSubview(source)
    try #require(window.makeFirstResponder(source))
    startSearch(on: source)
    let field = makeField(for: source)
    window.contentView?.addSubview(field)
    source.removeFromSuperview()
    try #require(window.firstResponder === window)
    if reattach {
      window.contentView?.addSubview(source)
    }
    await Task.megaYield()

    #expect(field.currentEditor() != nil)
    #expect(!source.bridge.state.searchFocusPending)
  }

  @Test func pendingFindDoesNotFollowSourceToAnotherWindow() async throws {
    let window = makeWindow()
    let otherWindow = makeWindow()
    let source = makeSurface(runtime: GhosttyRuntime())
    window.contentView?.addSubview(source)
    try #require(window.makeFirstResponder(source))
    startSearch(on: source)
    let field = makeField(for: source)
    window.contentView?.addSubview(field)
    source.removeFromSuperview()
    otherWindow.contentView?.addSubview(source)
    await Task.megaYield()

    #expect(field.currentEditor() == nil)
    #expect(!source.bridge.state.searchFocusPending)
  }

  @Test func splitZoomPreservesSearchFocusAfterResponderFallback() async throws {
    let window = SearchFocusTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled], backing: .buffered, defer: true
    )
    let runtime = GhosttyRuntime()
    let state = WorktreeTerminalState(
      runtime: runtime,
      worktree: Worktree(
        id: "/tmp/repo/wt-1", name: "wt-1", detail: "",
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
        repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
      )
    )
    let tabID = try #require(state.createTab())
    let firstID = try #require(state.focusedSurfaceId(in: tabID))
    #expect(state.performSplitAction(.newSplit(direction: .right), for: firstID))
    let targetID = try #require(state.focusedSurfaceId(in: tabID))
    let target = try #require(state.surfaceView(for: targetID))
    window.contentView?.addSubview(target)
    let sourceControl = NSTextField(frame: NSRect(x: 0, y: 80, width: 180, height: 24))
    window.contentView?.addSubview(sourceControl)
    try #require(window.makeFirstResponder(sourceControl))
    let sourceEditor = try #require(sourceControl.currentEditor())
    try #require(window.firstResponder === sourceEditor)
    target.bridge.state.searchNeedle = ""
    let requests = runtime.focusRequests
    requests.beginSearch(for: target.bridge.state, in: window)
    target.bridge.state.searchFocusPending = true

    let field = GhosttySearchField.SearchField(frame: NSRect(x: 0, y: 40, width: 180, height: 24))
    field.focusRequests = requests
    field.focusOwner = target.bridge.state
    let binding = Binding(
      get: { target.bridge.state.searchFocusPending },
      set: { target.bridge.state.searchFocusPending = $0 }
    )
    field.updateFocusPending(binding)
    window.acceptsSearchField = false
    window.clearsResponderOnRejection = true
    window.contentView?.addSubview(field)
    field.requestFocus()
    await Task.megaYield()
    try #require(window.firstResponder === window)

    let request = try #require(requests.searchRequest(for: target.bridge.state))
    #expect(request.context?.matches(in: window) == true)
    #expect(state.performSplitAction(.toggleSplitZoom, for: targetID))
    #expect(requests.searchRequest(for: target.bridge.state)?.matches(request) == true)
    #expect(target.bridge.state.searchFocusPending)
  }

  @Test func newerTextFieldFocusBeforeFieldCreationCancelsSearch() async throws {
    let window = makeWindow()
    let source = makeSurface(runtime: GhosttyRuntime())
    let original = NSTextField(frame: NSRect(x: 0, y: 40, width: 180, height: 24))
    let newer = NSTextField(frame: NSRect(x: 0, y: 80, width: 180, height: 24))
    window.contentView?.addSubview(source)
    window.contentView?.addSubview(original)
    window.contentView?.addSubview(newer)
    try #require(window.makeFirstResponder(original))
    let originalEditor = try #require(original.currentEditor())
    startSearch(on: source)
    try #require(window.makeFirstResponder(newer))
    let editor = try #require(newer.currentEditor())
    try #require(editor === originalEditor)

    let field = makeField(for: source)
    window.contentView?.addSubview(field)
    await Task.megaYield()

    #expect(window.firstResponder === editor)
    #expect(newer.currentEditor() === editor)
    #expect(field.currentEditor() == nil)
    #expect(!source.bridge.state.searchFocusPending)
  }

  @Test func repeatedFindAfterTextFieldFocusBeforeFieldCreationTakesFocus() async throws {
    let window = makeWindow()
    let source = makeSurface(runtime: GhosttyRuntime())
    let other = NSTextField(frame: NSRect(x: 0, y: 40, width: 180, height: 24))
    window.contentView?.addSubview(source)
    window.contentView?.addSubview(other)
    startSearch(on: source)
    try #require(window.makeFirstResponder(other))
    startSearch(on: source)

    let field = makeField(for: source)
    window.contentView?.addSubview(field)
    await Task.megaYield()

    #expect(field.currentEditor() != nil)
    #expect(!source.bridge.state.searchFocusPending)
  }

  @Test func searchRequestFromAnotherWindowDoesNotFocusTheField() async throws {
    let originalWindow = makeWindow()
    let replacementWindow = makeWindow()
    let source = makeSurface(runtime: GhosttyRuntime())
    originalWindow.contentView?.addSubview(source)
    startSearch(on: source)
    replacementWindow.contentView?.addSubview(source)

    let field = makeField(for: source)
    replacementWindow.contentView?.addSubview(field)
    await Task.megaYield()

    #expect(field.currentEditor() == nil)
    #expect(!source.bridge.state.searchFocusPending)
  }

  @Test func newerTerminalFocusBeforeFieldCreationCancelsSearch() async throws {
    let window = makeWindow()
    let runtime = GhosttyRuntime()
    let source = makeSurface(runtime: runtime)
    let terminal = makeSurface(runtime: runtime)
    window.contentView?.addSubview(terminal)
    startSearch(on: source)
    terminal.requestFocus()
    await Task.megaYield()
    try #require(window.firstResponder === terminal)

    let field = makeField(for: source)
    window.contentView?.addSubview(field)
    await Task.megaYield()

    #expect(window.firstResponder === terminal)
    #expect(field.currentEditor() == nil)
    #expect(!source.bridge.state.searchFocusPending)
  }

  @Test func repeatedFindSupersedesANewerTerminalRequestWhilePending() async throws {
    let window = SearchFocusTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled], backing: .buffered, defer: true
    )
    let runtime = GhosttyRuntime()
    let source = makeSurface(runtime: runtime)
    let terminal = makeSurface(runtime: runtime)
    window.contentView?.addSubview(source)
    window.contentView?.addSubview(terminal)
    startSearch(on: source)
    let field = makeField(for: source)
    window.acceptsSearchField = false
    window.contentView?.addSubview(field)
    await Task.megaYield()
    try #require(source.bridge.state.searchFocusPending)

    terminal.requestFocus()
    startSearch(on: source)
    window.acceptsSearchField = true
    field.requestFocus()
    await Task.megaYield()

    #expect(field.currentEditor() != nil)
    #expect(!source.bridge.state.searchFocusPending)
  }

  @Test func repeatedFindSupersedesANewerTextFieldFocusWhilePending() async throws {
    let window = SearchFocusTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled], backing: .buffered, defer: true
    )
    let source = makeSurface(runtime: GhosttyRuntime())
    window.contentView?.addSubview(source)
    startSearch(on: source)
    let field = makeField(for: source)
    let other = NSTextField(frame: NSRect(x: 0, y: 40, width: 180, height: 24))
    window.contentView?.addSubview(other)
    window.acceptsSearchField = false
    window.contentView?.addSubview(field)
    await Task.megaYield()
    try #require(source.bridge.state.searchFocusPending)

    try #require(window.makeFirstResponder(other))
    startSearch(on: source)
    window.acceptsSearchField = true
    field.requestFocus()
    await Task.megaYield()

    #expect(field.currentEditor() != nil)
    #expect(!source.bridge.state.searchFocusPending)
  }

  @Test func newerFindCancelsAnOlderTerminalRetry() async throws {
    let window = makeWindow()
    let runtime = GhosttyRuntime()
    let source = makeSurface(runtime: runtime)
    let terminal = makeSurface(runtime: runtime)
    let clock = TestClock()
    GhosttySurfaceView.moveFocus(to: terminal, clock: clock)
    await Task.megaYield()
    window.contentView?.addSubview(source)
    startSearch(on: source)
    let field = makeField(for: source)
    window.contentView?.addSubview(field)
    await Task.megaYield()
    let editor = try #require(field.currentEditor())

    window.contentView?.addSubview(terminal)
    await clock.advance(by: .seconds(2))
    await Task.megaYield()

    #expect(window.firstResponder === editor)
    #expect(field.currentEditor() === editor)
  }

  @Test func anotherSurfaceSearchCannotAuthorizeThisField() async throws {
    let window = makeWindow()
    let runtime = GhosttyRuntime()
    let source = makeSurface(runtime: runtime)
    let other = makeSurface(runtime: runtime)
    startSearch(on: source)
    startSearch(on: other)
    let field = makeField(for: source)
    window.contentView?.addSubview(field)
    await Task.megaYield()

    #expect(field.currentEditor() == nil)
    #expect(!source.bridge.state.searchFocusPending)
    #expect(other.bridge.state.searchFocusPending)
  }

  @Test func missingSearchRequestDoesNotFocusTheField() async throws {
    let window = makeWindow()
    var pending = true
    let field = GhosttySearchField.SearchField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
    field.updateFocusPending(Binding(get: { pending }, set: { pending = $0 }))
    window.contentView?.addSubview(field)
    await Task.megaYield()

    #expect(field.currentEditor() == nil)
    #expect(!pending)
  }

  @Test func focusRequestBeforeWindowAttachmentIsAppliedAfterAttachment() async throws {
    let window = makeWindow()
    let other = NSTextField(frame: NSRect(x: 0, y: 40, width: 180, height: 24))
    window.contentView?.addSubview(other)
    try #require(window.makeFirstResponder(other))
    let originalResponder = try #require(window.firstResponder)
    var pending = true
    let field = makeField(focusPending: Binding(get: { pending }, set: { pending = $0 }), in: window)

    field.requestFocus()
    await Task.megaYield()
    #expect(pending)
    #expect(window.firstResponder === originalResponder)

    window.contentView?.addSubview(field)
    await Task.megaYield()

    let editor = try #require(field.currentEditor())
    #expect(window.firstResponder === editor)
    #expect(!pending)
  }

  @Test func pendingRequestRetriesWhenFirstResponderDidNotActuallyChange() async throws {
    let window = SearchFocusTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled], backing: .buffered, defer: true
    )
    let other = NSTextField(frame: NSRect(x: 0, y: 40, width: 180, height: 24))
    window.contentView?.addSubview(other)
    try #require(window.makeFirstResponder(other))
    let otherEditor = try #require(other.currentEditor())
    var pending = true
    let field = makeField(focusPending: Binding(get: { pending }, set: { pending = $0 }), in: window)
    window.acceptsSearchField = false
    window.contentView?.addSubview(field)
    field.requestFocus()
    await Task.megaYield()
    #expect(window.firstResponder === otherEditor)
    #expect(pending)

    pending = true
    field.requestFocus()
    await Task.megaYield()
    #expect(window.firstResponder === otherEditor)
    #expect(pending)

    window.acceptsSearchField = true
    window.update()
    await Task.megaYield()

    let editor = try #require(field.currentEditor())
    #expect(window.firstResponder === editor)
    #expect(!pending)
  }

  @Test("A failed focus attempt retries only if no later control has focus", arguments: [false, true])
  func retriesAfterWindowFallback(newerTextFieldFocus: Bool) async throws {
    let window = SearchFocusTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled], backing: .buffered, defer: true
    )
    let original = NSTextField(frame: NSRect(x: 0, y: 40, width: 180, height: 24))
    let newer = NSTextField(frame: NSRect(x: 0, y: 80, width: 180, height: 24))
    window.contentView?.addSubview(original)
    window.contentView?.addSubview(newer)
    try #require(window.makeFirstResponder(original))
    var pending = true
    let field = makeField(focusPending: Binding(get: { pending }, set: { pending = $0 }), in: window)
    window.acceptsSearchField = false
    window.clearsResponderOnRejection = true
    window.contentView?.addSubview(field)
    await Task.megaYield()
    try #require(window.firstResponder === window)
    try #require(field.currentEditor() == nil)
    try #require(pending)

    if newerTextFieldFocus {
      try #require(window.makeFirstResponder(newer))
    }
    window.acceptsSearchField = true
    window.update()
    await Task.megaYield()

    #expect(!pending)
    if newerTextFieldFocus {
      #expect(newer.currentEditor() != nil)
      #expect(field.currentEditor() == nil)
    } else {
      let editor = try #require(field.currentEditor())
      #expect(window.firstResponder === editor)
    }
  }

  @Test func pendingRequestDoesNotOverrideANewerTextFieldFocus() async throws {
    let window = SearchFocusTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled], backing: .buffered, defer: true
    )
    let original = NSTextField(frame: NSRect(x: 0, y: 40, width: 180, height: 24))
    let newer = NSTextField(frame: NSRect(x: 0, y: 80, width: 180, height: 24))
    window.contentView?.addSubview(original)
    window.contentView?.addSubview(newer)
    try #require(window.makeFirstResponder(original))
    var pending = true
    let field = makeField(focusPending: Binding(get: { pending }, set: { pending = $0 }), in: window)
    window.acceptsSearchField = false
    window.contentView?.addSubview(field)
    await Task.megaYield()
    try #require(pending)

    try #require(window.makeFirstResponder(newer))
    let editor = try #require(newer.currentEditor())
    window.acceptsSearchField = true
    window.update()
    await Task.megaYield()

    #expect(newer.currentEditor() === editor)
    #expect(field.currentEditor() == nil)
    #expect(!pending)

    pending = true
    try startSearch(on: field)
    field.requestFocus()
    await Task.megaYield()
    #expect(field.currentEditor() != nil)
    #expect(!pending)
  }

  @Test func newerTerminalRequestCancelsPendingSearchBeforeAttachment() async throws {
    let window = makeWindow()
    let runtime = GhosttyRuntime()
    let terminal = GhosttySurfaceView(
      runtime: runtime, workingDirectory: nil, context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    let clock = TestClock()
    var pending = true
    let field = makeField(focusPending: Binding(get: { pending }, set: { pending = $0 }), in: window)

    GhosttySurfaceView.moveFocus(to: terminal, clock: clock, requests: field.focusRequests)
    await Task.megaYield()
    window.contentView?.addSubview(field)
    await Task.megaYield()

    #expect(!pending)
    #expect(field.currentEditor() == nil)

    window.contentView?.addSubview(terminal)
    await clock.advance(by: .seconds(2))
    await Task.megaYield()
    #expect(window.firstResponder === terminal)
  }

  @Test func dismantledFieldCannotConsumeItsReplacementRequest() async throws {
    let window = makeWindow()
    var pending = true
    let binding = Binding(get: { pending }, set: { pending = $0 })
    let original = makeField(focusPending: binding, in: window)
    window.contentView?.addSubview(original)
    GhosttySearchField.dismantleNSView(original, coordinator: .init(text: .constant("")))
    let replacement = makeField(focusPending: binding, in: window)
    window.contentView?.addSubview(replacement)
    await Task.megaYield()

    #expect(original.currentEditor() == nil)
    #expect(replacement.currentEditor() != nil)
    #expect(!pending)
  }

  @Test func focusedRemovalDoesNotRestoreAfterNewerTextFieldFocus() async throws {
    let window = makeWindow()
    var pending = true
    var restoreRequested = false
    let field = makeField(focusPending: Binding(get: { pending }, set: { pending = $0 }), in: window)
    field.onFocusedRemoval = { _ in restoreRequested = true }
    let other = NSTextField(frame: NSRect(x: 0, y: 40, width: 180, height: 24))
    window.contentView?.addSubview(field)
    window.contentView?.addSubview(other)
    await Task.megaYield()
    try #require(field.currentEditor() != nil)

    field.stopRequestingFocus()
    try #require(window.makeFirstResponder(other))
    await Task.megaYield()

    #expect(!restoreRequested)
    #expect(other.currentEditor() != nil)
    #expect(!pending)
  }

  @Test func newerTerminalRequestBeforeRemovalPreventsFocusTransfer() async throws {
    let window = makeWindow()
    var pending = true
    var restoreRequested = false
    let field = makeField(focusPending: Binding(get: { pending }, set: { pending = $0 }), in: window)
    field.onFocusedRemoval = { _ in restoreRequested = true }
    window.contentView?.addSubview(field)
    await Task.megaYield()
    try #require(field.currentEditor() != nil)
    try #require(!pending)
    let terminal = makeSurface(runtime: GhosttyRuntime())
    let clock = TestClock()

    GhosttySurfaceView.moveFocus(to: terminal, clock: clock, requests: field.focusRequests)
    field.stopRequestingFocus()
    await Task.megaYield()

    #expect(!restoreRequested)
    window.contentView?.addSubview(terminal)
    await clock.advance(by: .seconds(2))
    await Task.megaYield()
    #expect(window.firstResponder === terminal)
  }

  @Test func focusedRemovalDoesNotRestoreAfterNewerTerminalRequest() async throws {
    let window = makeWindow()
    var pending = true
    var restoreRequested = false
    let field = makeField(focusPending: Binding(get: { pending }, set: { pending = $0 }), in: window)
    field.onFocusedRemoval = { _ in restoreRequested = true }
    window.contentView?.addSubview(field)
    await Task.megaYield()
    try #require(field.currentEditor() != nil)
    let runtime = GhosttyRuntime()
    let terminal = GhosttySurfaceView(
      runtime: runtime, workingDirectory: nil, context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    let clock = TestClock()

    field.stopRequestingFocus()
    GhosttySurfaceView.moveFocus(to: terminal, clock: clock, requests: field.focusRequests)
    await Task.megaYield()
    #expect(!restoreRequested)
    #expect(!pending)

    window.contentView?.addSubview(terminal)
    await clock.advance(by: .seconds(2))
    await Task.megaYield()
    #expect(window.firstResponder === terminal)
  }

  @Test func repeatedPendingRequestsShareOneFocusTask() async throws {
    let window = SearchFocusTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled], backing: .buffered, defer: true
    )
    var pending = true
    let field = makeField(focusPending: Binding(get: { pending }, set: { pending = $0 }), in: window)
    window.contentView?.addSubview(field)
    window.searchFieldFocusAttemptCount = 0

    field.requestFocus()
    field.requestFocus()
    field.requestFocus()
    await Task.megaYield()

    #expect(window.searchFieldFocusAttemptCount == 1)
    #expect(!pending)
  }

  @Test func completedRequestDoesNotTakeFocusBackOnUpdate() async throws {
    let window = makeWindow()
    var pending = true
    let field = makeField(focusPending: Binding(get: { pending }, set: { pending = $0 }), in: window)
    let other = NSTextField(frame: NSRect(x: 0, y: 40, width: 180, height: 24))
    window.contentView?.addSubview(field)
    window.contentView?.addSubview(other)
    field.requestFocus()
    await Task.megaYield()
    try #require(field.currentEditor() != nil)
    #expect(!pending)
    try #require(window.makeFirstResponder(other))
    let editor = try #require(other.currentEditor())

    field.requestFocus()
    window.update()
    await Task.megaYield()

    #expect(!pending)
    #expect(window.firstResponder === editor)
    #expect(other.currentEditor() === editor)
    #expect(field.currentEditor() == nil)
  }

  @Test func newSearchRequestTakesFocusBack() async throws {
    let window = makeWindow()
    var pending = true
    let field = makeField(focusPending: Binding(get: { pending }, set: { pending = $0 }), in: window)
    let other = NSTextField(frame: NSRect(x: 0, y: 40, width: 180, height: 24))
    window.contentView?.addSubview(field)
    window.contentView?.addSubview(other)
    field.requestFocus()
    await Task.megaYield()
    #expect(!pending)
    try #require(window.makeFirstResponder(other))

    pending = true
    try startSearch(on: field)
    field.requestFocus()
    await Task.megaYield()

    let editor = try #require(field.currentEditor())
    #expect(window.firstResponder === editor)
    #expect(!pending)
  }

  @Test func detachedFieldDoesNotApplyDeferredFocus() async throws {
    let window = makeWindow()
    let other = NSTextField(frame: NSRect(x: 0, y: 40, width: 180, height: 24))
    window.contentView?.addSubview(other)
    try #require(window.makeFirstResponder(other))
    let originalResponder = try #require(window.firstResponder)
    var pending = true
    let field = makeField(focusPending: Binding(get: { pending }, set: { pending = $0 }), in: window)

    window.contentView?.addSubview(field)
    field.removeFromSuperview()
    window.update()
    await Task.megaYield()

    #expect(pending)
    #expect(window.firstResponder === originalResponder)
    #expect(other.currentEditor() === originalResponder)
  }

  @Test func cancelledRequestDoesNotApplyDeferredFocus() async throws {
    let window = makeWindow()
    let other = NSTextField(frame: NSRect(x: 0, y: 40, width: 180, height: 24))
    window.contentView?.addSubview(other)
    try #require(window.makeFirstResponder(other))
    let originalResponder = try #require(window.firstResponder)
    var pending = true
    let field = makeField(focusPending: Binding(get: { pending }, set: { pending = $0 }), in: window)

    window.contentView?.addSubview(field)
    pending = false
    window.update()
    await Task.megaYield()

    #expect(!pending)
    #expect(window.firstResponder === originalResponder)
    #expect(field.currentEditor() == nil)
  }

  @Test func deferredFocusUsesTheCurrentBinding() async throws {
    let window = makeWindow()
    let other = NSTextField(frame: NSRect(x: 0, y: 40, width: 180, height: 24))
    window.contentView?.addSubview(other)
    try #require(window.makeFirstResponder(other))
    let originalResponder = try #require(window.firstResponder)
    var pending = true
    let field = makeField(focusPending: Binding(get: { pending }, set: { pending = $0 }), in: window)
    window.contentView?.addSubview(field)

    field.updateFocusPending(.constant(false))
    await Task.megaYield()

    #expect(pending)
    #expect(window.firstResponder === originalResponder)
  }

  @Test func missingBindingDoesNotRequestFocus() async throws {
    let window = makeWindow()
    let other = NSTextField(frame: NSRect(x: 0, y: 40, width: 180, height: 24))
    window.contentView?.addSubview(other)
    try #require(window.makeFirstResponder(other))
    let originalResponder = try #require(window.firstResponder)
    let field = GhosttySearchField.SearchField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))

    window.contentView?.addSubview(field)
    field.requestFocus()
    window.update()
    await Task.megaYield()

    #expect(window.firstResponder === originalResponder)
  }

  private func makeSurface(runtime: GhosttyRuntime) -> GhosttySurfaceView {
    GhosttySurfaceView(
      runtime: runtime, workingDirectory: nil, context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
  }

  private func startSearch(on surface: GhosttySurfaceView) {
    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_START_SEARCH
    _ = surface.bridge.handleAction(target: ghostty_target_s(), action: action)
  }

  private func startSearch(on field: GhosttySearchField.SearchField) throws {
    let requests = try #require(field.focusRequests)
    let owner = try #require(field.focusOwner)
    requests.beginSearch(for: owner, in: field.window)
  }

  private func makeField(for surface: GhosttySurfaceView) -> GhosttySearchField.SearchField {
    let field = GhosttySearchField.SearchField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
    field.focusRequests = surface.runtime.focusRequests
    field.focusOwner = surface.bridge.state
    let state = surface.bridge.state
    field.updateFocusPending(Binding(get: { state.searchFocusPending }, set: { state.searchFocusPending = $0 }))
    return field
  }

  private func makeWindow() -> NSWindow {
    NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled], backing: .buffered, defer: true
    )
  }

  private func makeField(focusPending: Binding<Bool>, in window: NSWindow) -> GhosttySearchField.SearchField {
    let field = GhosttySearchField.SearchField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
    let requests = GhosttySurfaceView.FocusRequests()
    let owner = GhosttySurfaceState()
    requests.beginSearch(for: owner, in: window)
    field.focusRequests = requests
    field.focusOwner = owner
    field.updateFocusPending(focusPending)
    return field
  }
}

@MainActor
private final class SearchFocusTestWindow: NSWindow {
  var acceptsSearchField = true
  var clearsResponderOnRejection = false
  var searchFieldFocusAttemptCount = 0

  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
    if responder is GhosttySearchField.SearchField {
      searchFieldFocusAttemptCount += 1
    }
    guard acceptsSearchField || !(responder is GhosttySearchField.SearchField) else {
      if clearsResponderOnRejection {
        _ = super.makeFirstResponder(nil)
      }
      return true
    }
    return super.makeFirstResponder(responder)
  }
}
