import AppKit
import Testing

@testable import supacode

struct WindowTabbingDisablerTests {
  @Test func shouldNotOrderOutFullscreenWindowOnClose() {
    #expect(WindowTabbingView.shouldOrderOutOnClose(styleMask: [.titled, .fullScreen]) == false)
  }

  @Test func shouldOrderOutNonFullscreenWindowOnClose() {
    #expect(WindowTabbingView.shouldOrderOutOnClose(styleMask: [.titled, .closable]) == true)
  }
}
