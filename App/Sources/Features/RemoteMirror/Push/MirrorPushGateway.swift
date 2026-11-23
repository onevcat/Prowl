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
  /// `reason` is the gateway's code or APNs reason, `http-<status>`, or `network`; it names no
  /// device or content.
  case failed(reason: String)
}

nonisolated struct MirrorPushDelivery: Equatable, Sendable {
  let date: Date
  let result: MirrorPushGatewayResult
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
      let (data, response) = try await session.data(for: request)
      return Self.result(statusCode: (response as? HTTPURLResponse)?.statusCode, body: data)
    } catch {
      ProwlLogger("RemoteMirror").warning("Push gateway request failed", error: error)
      return .failed(reason: "network")
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

  static func result(statusCode: Int?, body: Data? = nil) -> MirrorPushGatewayResult {
    switch statusCode {
    case .some(200...299): .accepted
    case .some(410): .tokenGone
    case .some(let code): .failed(reason: reason(body) ?? "http-\(code)")
    case nil: .failed(reason: "network")
    }
  }

  /// The failure body `{"error": code, "reason": APNs reason}` (contract: `gateway.pushFailures`).
  /// Only a short code survives, since it goes into logs and Settings.
  static func reason(_ body: Data?) -> String? {
    struct Failure: Decodable {
      let error: String?
      let reason: String?
    }
    guard let body, let failure = try? JSONDecoder().decode(Failure.self, from: body),
      let text = failure.reason ?? failure.error
    else { return nil }
    let code = String(text.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }.prefix(64))
    return code.isEmpty ? nil : code
  }
}
