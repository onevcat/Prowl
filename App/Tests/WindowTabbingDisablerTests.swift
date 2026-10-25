import AppKit
import Testing

@testable import Prowl

@MainActor
struct WindowTabbingDisablerTests {
  @Test func shouldNotOrderOutFullscreenWindowOnClose() {
    #expect(WindowTabbingView.shouldOrderOutOnClose(styleMask: [.titled, .fullScreen]) == false)
  }

  @Test func shouldOrderOutNonFullscreenWindowOnClose() {
    #expect(WindowTabbingView.shouldOrderOutOnClose(styleMask: [.titled, .closable]) == true)
  }

  @Test func mainWindowForwardsOtherDelegateMessagesToTheOriginalDelegate() {
    let fixture = makeMainWindow()
    let window = fixture.window
    let original = fixture.original
    defer { withExtendedLifetime(fixture.view) {} }

    #expect(window.delegate !== original)
    #expect(window.delegate?.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))) == true)
    window.delegate?.windowDidResize?(Notification(name: NSWindow.didResizeNotification, object: window))
    #expect(original.didResizeCount == 1)
  }

  @Test func mainWindowCloseOrdersOutWithoutAskingTheOriginalDelegate() {
    let fixture = makeMainWindow()
    let window = fixture.window
    let original = fixture.original
    defer { withExtendedLifetime(fixture.view) {} }
    window.orderFront(nil)

    #expect(window.delegate?.windowShouldClose?(window) == false)
    #expect(window.isVisible == false)
    #expect(original.shouldCloseCount == 0)
  }

  @Test func repeatedInstallsKeepForwardingToTheOriginalDelegate() {
    let fixture = makeMainWindow()
    let window = fixture.window
    let original = fixture.original
    let view = fixture.view
    view.disallowTabbing()
    view.disallowTabbing()

    window.delegate?.windowDidResize?(Notification(name: NSWindow.didResizeNotification, object: window))
    #expect(original.didResizeCount == 1)
  }

  @Test func aReplacedDelegateIsWrappedAgain() {
    let fixture = makeMainWindow()
    let window = fixture.window
    let original = fixture.original
    let view = fixture.view
    let replacement = RecordingWindowDelegate()
    window.delegate = replacement
    view.disallowTabbing()

    #expect(window.delegate !== replacement)
    window.delegate?.windowDidResize?(Notification(name: NSWindow.didResizeNotification, object: window))
    #expect(replacement.didResizeCount == 1)
    #expect(original.didResizeCount == 0)
  }

  @Test func aNewViewTakesOverTheOriginalDelegateFromAnEarlierProxy() {
    let fixture = makeMainWindow()
    let window = fixture.window
    let original = fixture.original
    let laterView = WindowTabbingView()
    window.contentView?.addSubview(laterView)
    fixture.view.removeFromSuperview()

    window.delegate?.windowDidResize?(Notification(name: NSWindow.didResizeNotification, object: window))
    #expect(original.didResizeCount == 1)
    #expect((window.delegate as? MainWindowDelegateProxy)?.forwardee === original)
  }

  private func makeMainWindow() -> MainWindowFixture {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true
    )
    window.isReleasedWhenClosed = false
    let original = RecordingWindowDelegate()
    window.delegate = original
    let view = WindowTabbingView()
    window.contentView?.addSubview(view)
    return MainWindowFixture(window: window, original: original, view: view)
  }
}

private struct MainWindowFixture {
  let window: NSWindow
  let original: RecordingWindowDelegate
  let view: WindowTabbingView
}

private final class RecordingWindowDelegate: NSObject, NSWindowDelegate {
  var didResizeCount = 0
  var shouldCloseCount = 0

  func windowDidResize(_ notification: Notification) {
    didResizeCount += 1
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    shouldCloseCount += 1
    return true
  }
}
