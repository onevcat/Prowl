import AppKit
import GhosttyKit
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct CanvasCardEventRoutingTests {
  @Test func commandClickOnFollowerLinkRoutesToGhosttyWithoutChangingSelection() async throws {
    let fixture = CanvasCardEventRoutingFixture(hasHoveredLink: true)
    defer { fixture.close() }
    await fixture.prepareForHitTesting()

    let target = try #require(fixture.sendCommandClick())
    await fixture.drainMainQueue()

    #expect(target === fixture.surfaceView)
    #expect(fixture.tapRecorder.selectionTapCount == 0)
    #expect(fixture.tapRecorder.outerTapCount == 0)
  }

  @Test func commandClickOnFollowerNonLinkContentStillRoutesToSelection() async throws {
    let fixture = CanvasCardEventRoutingFixture(hasHoveredLink: false)
    defer { fixture.close() }
    await fixture.prepareForHitTesting()

    let target = try #require(fixture.sendCommandClick())
    await fixture.drainMainQueue()

    #expect(target !== fixture.surfaceView)
    #expect(fixture.tapRecorder.selectionTapCount == 1)
    #expect(fixture.tapRecorder.outerTapCount == 0)
  }

  @Test func plainClickOnFocusedCardTerminalDoesNotChangeSelection() async throws {
    let fixture = CanvasCardEventRoutingFixture(hasHoveredLink: false, isFocused: true)
    defer { fixture.close() }
    await fixture.prepareForHitTesting()

    let target = try #require(fixture.sendClick(modifierFlags: []))
    await fixture.drainMainQueue()

    #expect(target === fixture.surfaceView)
    #expect(fixture.tapRecorder.selectionTapCount == 0)
    #expect(fixture.tapRecorder.outerTapCount == 0)
  }
}

@MainActor
private final class CanvasCardEventRoutingFixture {
  let surfaceView: GhosttySurfaceView
  let tapRecorder = CanvasCardTapRecorder()

  private let cardSize = CGSize(width: 320, height: 200)
  private let window: NSWindow
  private let hostingView: NSHostingView<CanvasCardView>

  init(hasHoveredLink: Bool, isFocused: Bool = false) {
    let runtime = GhosttyRuntime()
    let surfaceView = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    self.surfaceView = surfaceView
    surfaceView.bridge.state.mouseOverLink = hasHoveredLink ? "https://example.com" : nil

    let tab = TerminalTabItem(title: "Follower", icon: nil)
    // A focused card models a plain click on the active card; every other
    // fixture models a Command-click on a broadcast follower.
    let linkActivationRequested = CanvasInteractionPolicy.linkActivationRequested(
      hasHoveredLink: CanvasInteractionPolicy.hasHoveredLink(in: SplitTree(view: surfaceView)),
      isCommandModifierActive: !isFocused
    )
    let showsSelectionShield = CanvasInteractionPolicy.showsSelectionShield(
      commandSelectionActive: !isFocused,
      selectionModeActive: !isFocused,
      broadcastFollower: !isFocused,
      linkActivationRequested: linkActivationRequested
    )
    let card = CanvasCardView(
      repositoryName: "Prowl",
      worktreeName: tab.displayTitle,
      tree: SplitTree(view: surfaceView),
      activeSurfaceID: surfaceView.id,
      unfocusedSplitOverlay: (nil, 0),
      isFocused: isFocused,
      isSelected: true,
      hasUnseenNotification: false,
      tabIcon: nil,
      tabId: tab.id,
      tabs: [tab],
      tabContextMenuActions: TerminalTabContextMenuActions(
        renameTab: { _ in },
        changeIcon: { _ in },
        closeTab: { _ in },
        closeOthers: { _ in },
        closeToRight: { _ in },
        closeAll: {}
      ),
      cardSize: cardSize,
      isExpanded: false,
      expandHelp: "Expand card",
      canvasScale: 1,
      linkActivationRequested: linkActivationRequested,
      showsSelectionShield: showsSelectionShield,
      onTap: { [tapRecorder] in tapRecorder.outerTapCount += 1 },
      onSelectionTap: { [tapRecorder] in tapRecorder.selectionTapCount += 1 },
      onDragCommit: { _ in },
      onResize: { _, _ in },
      onResizeEnd: {},
      onSplitOperation: { _ in },
      onTitleBarTap: {},
      onExpand: {},
      onClose: {}
    )

    let contentSize = CGSize(width: cardSize.width, height: cardSize.height + 28)
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: contentSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    hostingView = NSHostingView(rootView: card)
    hostingView.frame = NSRect(origin: .zero, size: contentSize)
    window.contentView = hostingView
  }

  func prepareForHitTesting() async {
    window.orderFront(nil)
    hostingView.layoutSubtreeIfNeeded()
    await drainMainQueue()
    hostingView.layoutSubtreeIfNeeded()
  }

  func sendCommandClick() -> NSView? {
    sendClick(modifierFlags: .command)
  }

  func sendClick(modifierFlags: NSEvent.ModifierFlags) -> NSView? {
    let point = NSPoint(x: cardSize.width / 2, y: cardSize.height / 2)
    let target = hostingView.hitTest(point)
    let locationInWindow = hostingView.convert(point, to: nil)
    let timestamp = ProcessInfo.processInfo.systemUptime

    guard
      let mouseDown = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: locationInWindow,
        modifierFlags: modifierFlags,
        timestamp: timestamp,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
      ),
      let mouseUp = NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: locationInWindow,
        modifierFlags: modifierFlags,
        timestamp: timestamp,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 2,
        clickCount: 1,
        pressure: 0
      )
    else {
      return nil
    }

    window.sendEvent(mouseDown)
    window.sendEvent(mouseUp)
    return target
  }

  func close() {
    window.orderOut(nil)
  }

  func drainMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        continuation.resume()
      }
    }
  }
}

@MainActor
private final class CanvasCardTapRecorder {
  var outerTapCount = 0
  var selectionTapCount = 0
}
