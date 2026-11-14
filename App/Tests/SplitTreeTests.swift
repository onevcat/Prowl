import AppKit
import ConcurrencyExtras
import SwiftUI
import Testing

@testable import Prowl

@MainActor
struct SplitTreeTests {
  @Test func activeSurfaceTracksClickAndGotoSplitPaths() throws {
    let state = makeWorktreeTerminalState()
    let tabId = try #require(state.createTab())
    let firstID = try #require(state.focusedSurfaceId(in: tabId))
    let first = try #require(state.surfaceView(for: firstID))

    #expect(state.performSplitAction(.newSplit(direction: .right), for: firstID))
    let secondID = try #require(state.focusedSurfaceId(in: tabId))
    let second = try #require(state.surfaceView(for: secondID))

    var emissions: [UUID] = []
    state.onFocusChanged = { emissions.append($0) }

    #expect(state.activeSurfaceID(for: tabId) == second.id)

    first.onFocusChange?(true)
    #expect(state.activeSurfaceID(for: tabId) == first.id)

    first.onFocusChange?(true)
    #expect(state.activeSurfaceID(for: tabId) == first.id)

    #expect(state.performSplitAction(.gotoSplit(direction: .next), for: first.id))
    #expect(state.activeSurfaceID(for: tabId) == second.id)

    #expect(state.focusSurface(id: second.id))
    #expect(state.activeSurfaceID(for: tabId) == second.id)

    second.onFocusChange?(false)
    #expect(state.activeSurfaceID(for: tabId) == second.id)

    #expect(emissions == [first.id, second.id])
  }

  @Test func splitZoomPreservesFocusedFindAndItsPane() async throws {
    let state = makeWorktreeTerminalState()
    let tabID = try #require(state.createTab())
    let firstID = try #require(state.focusedSurfaceId(in: tabID))
    #expect(state.performSplitAction(.newSplit(direction: .right), for: firstID))
    let targetID = try #require(state.focusedSurfaceId(in: tabID))
    let target = try #require(state.surfaceView(for: targetID))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled], backing: .buffered, defer: true
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView?.addSubview(target)
    let search = GhosttySearchField.SearchField(frame: NSRect(x: 0, y: 40, width: 180, height: 24))
    search.focusRequests = target.runtime.focusRequests
    search.focusOwner = target.bridge.state
    target.bridge.state.searchNeedle = ""
    window.contentView?.addSubview(search)
    try #require(window.makeFirstResponder(search))
    let editor = try #require(search.currentEditor())
    let request = try #require(target.runtime.focusRequests.searchRequest(for: target.bridge.state))

    #expect(state.performSplitAction(.toggleSplitZoom, for: targetID))
    await Task.megaYield()

    #expect(window.firstResponder === editor)
    #expect(search.currentEditor() === editor)
    #expect(target.runtime.focusRequests.searchRequest(for: target.bridge.state)?.matches(request) == true)
    #expect(state.activeSurfaceID(for: tabID) == targetID)
    #expect(state.splitTree(for: tabID).zoomed == state.splitTree(for: tabID).find(id: targetID))
    #expect(target.runtime.focusRequests.isSearchFieldFocused(for: target.bridge.state, in: window))

    #expect(state.performSplitAction(.toggleSplitZoom, for: targetID))
    #expect(target.bridge.state.searchNeedle != nil)
    #expect(target.runtime.focusRequests.searchRequest(for: target.bridge.state)?.matches(request) == true)
    #expect(target.runtime.focusRequests.isSearchFieldFocused(for: target.bridge.state, in: window))
    await Task.megaYield()

    #expect(window.firstResponder === editor)
    #expect(search.window === window)
    #expect(search.currentEditor() === editor)
    #expect(state.splitTree(for: tabID).zoomed == nil)
  }

  @Test(arguments: [false, true])
  func splitZoomPreservesAValidPendingFindRequest(reattach: Bool) async throws {
    let state = makeWorktreeTerminalState()
    let tabID = try #require(state.createTab())
    let firstID = try #require(state.focusedSurfaceId(in: tabID))
    #expect(state.performSplitAction(.newSplit(direction: .right), for: firstID))
    let targetID = try #require(state.focusedSurfaceId(in: tabID))
    let target = try #require(state.surfaceView(for: targetID))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled], backing: .buffered, defer: true
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView?.addSubview(target)
    try #require(window.makeFirstResponder(target))
    target.bridge.state.searchNeedle = ""
    let requests = target.runtime.focusRequests
    requests.beginSearch(for: target.bridge.state, in: window)
    target.bridge.state.searchFocusPending = true
    let search = GhosttySearchField.SearchField(frame: NSRect(x: 0, y: 40, width: 180, height: 24))
    search.focusRequests = requests
    search.focusOwner = target.bridge.state
    window.contentView?.addSubview(search)
    search.updateFocusPending(
      Binding(
        get: { target.bridge.state.searchFocusPending },
        set: { target.bridge.state.searchFocusPending = $0 }
      ))
    let request = try #require(requests.searchRequest(for: target.bridge.state))
    if reattach {
      target.removeFromSuperview()
      try #require(window.firstResponder === window)
      window.contentView?.addSubview(target)
    }

    #expect(state.performSplitAction(.toggleSplitZoom, for: targetID))
    #expect(requests.searchRequest(for: target.bridge.state)?.matches(request) == true)
    await Task.megaYield()

    #expect(search.currentEditor() != nil)
    #expect(!target.bridge.state.searchFocusPending)
  }

  @Test func closeOperationRemovesThePaneLikeTheTabBarCloseButton() throws {
    let state = makeWorktreeTerminalState()
    let tabId = try #require(state.createTab())
    let firstID = try #require(state.focusedSurfaceId(in: tabId))
    #expect(state.performSplitAction(.newSplit(direction: .right), for: firstID))
    let secondID = try #require(state.focusedSurfaceId(in: tabId))
    #expect(secondID != firstID)

    state.performSplitOperation(.close(surfaceId: secondID), in: tabId)

    #expect(state.splitTree(for: tabId).leaves().map(\.id) == [firstID])
    #expect(state.surfaceView(for: secondID) == nil)
    #expect(state.focusedSurfaceId(in: tabId) == firstID)
    #expect(state.tabManager.tabs.count == 1)

    // Closing a pane that is already gone changes nothing.
    state.performSplitOperation(.close(surfaceId: secondID), in: tabId)
    #expect(state.splitTree(for: tabId).leaves().map(\.id) == [firstID])
  }

  @Test func explicitAnchorSplitDoesNotUseTheFocusedSurface() throws {
    let state = makeWorktreeTerminalState()
    let tabID = try #require(state.createTab())
    let anchorID = try #require(state.focusedSurfaceId(in: tabID))

    #expect(state.performSplitAction(.newSplit(direction: .right), for: anchorID))
    let previouslyFocusedID = try #require(state.focusedSurfaceId(in: tabID))
    #expect(previouslyFocusedID != anchorID)

    let createdID = try state.createSplit(
      of: anchorID,
      direction: .left,
      initialInput: nil,
      additionalEnvironment: [:],
      focusing: true
    ).get()

    #expect(state.trees[tabID]?.leaves().map(\.id) == [createdID, anchorID, previouslyFocusedID])
    #expect(state.focusedSurfaceId(in: tabID) == createdID)
  }

  @Test func explicitAnchorSplitCanPreserveFocus() throws {
    let state = makeWorktreeTerminalState()
    let tabID = try #require(state.createTab())
    let anchorID = try #require(state.focusedSurfaceId(in: tabID))

    #expect(state.performSplitAction(.newSplit(direction: .right), for: anchorID))
    let focusedID = try #require(state.focusedSurfaceId(in: tabID))

    _ = try state.createSplit(
      of: anchorID,
      direction: .left,
      initialInput: nil,
      additionalEnvironment: [:],
      focusing: false
    ).get()

    #expect(state.focusedSurfaceId(in: tabID) == focusedID)
  }

  @Test func explicitAnchorSplitReportsMissingAnchor() throws {
    let state = makeWorktreeTerminalState()
    _ = try #require(state.createTab())
    let missingID = UUID()

    switch state.createSplit(
      of: missingID,
      direction: .right,
      initialInput: nil,
      additionalEnvironment: [:],
      focusing: true
    ) {
    case .success:
      Issue.record("Expected the split to reject an unknown anchor")
    case .failure(let error):
      #expect(error == .anchorNotFound(missingID))
    }
  }

  @Test func focusTargetAfterClosingUsesNextForLeftmostLeaf() throws {
    let first = SplitTreeTestView()
    let second = SplitTreeTestView()
    let third = SplitTreeTestView()

    let tree = try SplitTree(view: first)
      .inserting(view: second, at: first, direction: .right)
      .inserting(view: third, at: second, direction: .right)

    let node = try #require(tree.find(id: first.id))
    #expect(tree.focusTargetAfterClosing(node) === second)
  }

  @Test func focusTargetAfterClosingUsesPreviousForNonLeftmostLeaf() throws {
    let first = SplitTreeTestView()
    let second = SplitTreeTestView()
    let third = SplitTreeTestView()

    let tree = try SplitTree(view: first)
      .inserting(view: second, at: first, direction: .right)
      .inserting(view: third, at: second, direction: .right)

    let node = try #require(tree.find(id: third.id))
    #expect(tree.focusTargetAfterClosing(node) === second)
  }

  @Test func visibleLeavesOnlyReturnZoomedPane() throws {
    let first = SplitTreeTestView()
    let second = SplitTreeTestView()

    let tree = try SplitTree(view: first)
      .inserting(view: second, at: first, direction: .right)

    let zoomed = tree.settingZoomed(tree.find(id: second.id))
    let visibleLeaves = zoomed.visibleLeaves()

    #expect(visibleLeaves.count == 1)
    #expect(visibleLeaves.first === second)
  }

  private func makeWorktreeTerminalState() -> WorktreeTerminalState {
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
}

private final class SplitTreeTestView: NSView, Identifiable {
  let id = UUID()
}
