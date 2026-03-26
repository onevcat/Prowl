import Foundation
import Testing

@testable import supacode

struct CanvasDirectoryShorteningCoordinatorTests {
  @Test func nextTokenIncrementsForTab() {
    var tokens: [TerminalTabID: CanvasDirectoryShorteningCoordinator.Token] = [:]
    let tabID = tab("00000000-0000-0000-0000-000000000001")

    let first = CanvasDirectoryShorteningCoordinator.nextToken(for: tabID, tokens: &tokens)
    let second = CanvasDirectoryShorteningCoordinator.nextToken(for: tabID, tokens: &tokens)

    #expect(first == 1)
    #expect(second == 2)
  }

  @Test func shouldApplyReturnsTrueOnlyForLatestToken() {
    var tokens: [TerminalTabID: CanvasDirectoryShorteningCoordinator.Token] = [:]
    let tabID = tab("00000000-0000-0000-0000-000000000001")

    let stale = CanvasDirectoryShorteningCoordinator.nextToken(for: tabID, tokens: &tokens)
    let latest = CanvasDirectoryShorteningCoordinator.nextToken(for: tabID, tokens: &tokens)

    #expect(CanvasDirectoryShorteningCoordinator.shouldApply(token: stale, for: tabID, latestTokens: tokens) == false)
    #expect(CanvasDirectoryShorteningCoordinator.shouldApply(token: latest, for: tabID, latestTokens: tokens))
  }

  @Test func recordsReplacementOfInFlightRequestForTab() {
    var requests: [TerminalTabID: String] = [:]
    let tabID = tab("00000000-0000-0000-0000-000000000001")

    let first = CanvasDirectoryShorteningCoordinator.replaceInFlightRequest(
      for: tabID,
      with: "request-1",
      requests: &requests
    )
    let second = CanvasDirectoryShorteningCoordinator.replaceInFlightRequest(
      for: tabID,
      with: "request-2",
      requests: &requests
    )

    #expect(first == nil)
    #expect(second == "request-1")
    #expect(requests[tabID] == "request-2")
  }

  @Test func pruneRequestsReturnsRemovedItems() {
    var requests: [TerminalTabID: String] = [
      tab("00000000-0000-0000-0000-000000000001"): "active",
      tab("00000000-0000-0000-0000-000000000002"): "stale",
    ]

    let removed = CanvasDirectoryShorteningCoordinator.pruneRequests(
      keeping: [tab("00000000-0000-0000-0000-000000000001")],
      requests: &requests
    )

    #expect(removed == ["stale"])
    #expect(requests.count == 1)
  }

  private func tab(_ value: String) -> TerminalTabID {
    TerminalTabID(rawValue: UUID(uuidString: value)!)
  }
}
