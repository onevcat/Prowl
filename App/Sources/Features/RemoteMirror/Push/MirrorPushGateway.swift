import Foundation

/// The Host's view of the push gateway: one request per event, no other traffic (docs-ai 095).
nonisolated protocol MirrorPushGateway: Sendable {
  func push(token: String, collapseID: String, sealed: String) async -> MirrorPushGatewayResult
}

nonisolated enum MirrorPushGatewayResult: Equatable, Sendable {
  case accepted
  /// The token is gone at the gateway (deleted, expired, or the app was removed).
  case tokenGone
  /// Rate limited, invalid, a server error or a network error: drop this event, keep the token.
  case failed
}

nonisolated struct URLSessionMirrorPushGateway: MirrorPushGateway {
  /// The `remoteMirrorPushGatewayURL` default overrides it for testing.
  static let defaultBaseURL = MirrorPushContract.gatewayURL

  let baseURL: URL
  let session: URLSession

  init(baseURL: URL, session: URLSession = .shared) {
    self.baseURL = baseURL
    self.session = session
  }

  static func configured(defaults: UserDefaults = .standard) -> Self {
    let override = defaults.string(forKey: "remoteMirrorPushGatewayURL").flatMap(URL.init(string:))
    return Self(baseURL: override ?? defaultBaseURL)
  }

  func push(token: String, collapseID: String, sealed: String) async -> MirrorPushGatewayResult {
    do {
      let request = try Self.pushRequest(baseURL: baseURL, token: token, collapseID: collapseID, sealed: sealed)
      let (_, response) = try await session.data(for: request)
      return Self.result(statusCode: (response as? HTTPURLResponse)?.statusCode)
    } catch {
      ProwlLogger("RemoteMirror").warning("Push gateway request failed", error: error)
      return .failed
    }
  }

  /// `POST /v1/push` (contract: `Mirror/Fixtures/push/contract.json`, `gateway`).
  static func pushRequest(baseURL: URL, token: String, collapseID: String, sealed: String) throws -> URLRequest {
    var request = URLRequest(url: baseURL.appending(path: "v1/push"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 15
    request.httpBody = try JSONEncoder().encode(["pushToken": token, "collapseID": collapseID, "sealed": sealed])
    return request
  }

  static func result(statusCode: Int?) -> MirrorPushGatewayResult {
    switch statusCode {
    case .some(200...299): .accepted
    case .some(410): .tokenGone
    default: .failed
    }
  }
}
