import Foundation
import Testing

@testable import supacode

struct CanvasFocusRequestHandlingTests {
  @Test func focusRequestDefaultsToPreservingViewportContext() {
    let request = CanvasFocusRequest(
      id: 1,
      target: .tab(TerminalTabID(rawValue: UUID()))
    )

    #expect(!request.shouldCenterInViewport)
  }

  @Test func focusRequestCanAskCanvasToCenterTargetInViewport() {
    let request = CanvasFocusRequest(
      id: 2,
      target: .tab(TerminalTabID(rawValue: UUID())),
      shouldCenterInViewport: true
    )

    #expect(request.shouldCenterInViewport)
  }
}
