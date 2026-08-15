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

  @Test func pendingTabRequestResolvesOnlyAfterCandidateAppears() {
    let requestedTabID = TerminalTabID(rawValue: UUID())
    let request = CanvasFocusRequest(id: 3, target: .tab(requestedTabID))

    let unresolved = CanvasFocusResolver.resolve(
      request: request,
      candidates: [],
      currentPrimaryTabID: nil
    )
    let resolved = CanvasFocusResolver.resolve(
      request: request,
      candidates: [CanvasFocusCandidate(worktreeID: "/tmp/repo/wt3", tabID: requestedTabID)],
      currentPrimaryTabID: nil
    )

    #expect(unresolved == nil)
    #expect(resolved == requestedTabID)
  }
}
