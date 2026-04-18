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

  @Test func keepsPreviousTokenWhenPendingRequestCannotBeHandledYet() {
    let oldToken = UUID()
    let request = CanvasView.FocusRequest(
      worktreeID: "/tmp/repo/wt3",
      tabID: TerminalTabID(rawValue: UUID()),
      token: UUID()
    )

    let nextToken = nextHandledCanvasFocusRequestToken(
      request: request,
      lastHandledToken: oldToken,
      didHandleRequest: false
    )

    #expect(nextToken == oldToken)
  }

  @Test func advancesTokenWhenPendingRequestIsHandled() {
    let oldToken = UUID()
    let newToken = UUID()
    let request = CanvasView.FocusRequest(
      worktreeID: "/tmp/repo/wt4",
      tabID: TerminalTabID(rawValue: UUID()),
      token: newToken
    )

    let nextToken = nextHandledCanvasFocusRequestToken(
      request: request,
      lastHandledToken: oldToken,
      didHandleRequest: true
    )

    #expect(nextToken == newToken)
  }
}
