import Foundation

struct CanvasDirectoryShorteningCoordinator {
  typealias Token = UInt64

  static func nextToken(for tabID: TerminalTabID, tokens: inout [TerminalTabID: Token]) -> Token {
    let nextToken = (tokens[tabID] ?? 0) &+ 1
    tokens[tabID] = nextToken
    return nextToken
  }

  static func shouldApply(token: Token, for tabID: TerminalTabID, latestTokens: [TerminalTabID: Token]) -> Bool {
    latestTokens[tabID] == token
  }

  static func replaceInFlightRequest<Request>(
    for tabID: TerminalTabID,
    with request: Request,
    requests: inout [TerminalTabID: Request]
  ) -> Request? {
    requests.updateValue(request, forKey: tabID)
  }

  static func pruneRequests<Request>(
    keeping activeTabIDs: Set<TerminalTabID>,
    requests: inout [TerminalTabID: Request]
  ) -> [Request] {
    let staleIDs = requests.keys.filter { !activeTabIDs.contains($0) }
    var removed: [Request] = []
    for staleID in staleIDs {
      if let removedRequest = requests.removeValue(forKey: staleID) {
        removed.append(removedRequest)
      }
    }
    return removed
  }
}
