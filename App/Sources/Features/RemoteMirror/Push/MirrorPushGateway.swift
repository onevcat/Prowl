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
  /// The development gateway (sandbox APNs), for Debug builds only. A Release build has no
  /// default until a production gateway exists, so it cannot send to the sandbox by mistake.
  /// The `remoteMirrorPushGatewayURL` default overrides it for self-built apps and testing.
  static let defaultBaseURL: URL? = {
    #if DEBUG
      URL(string: "https://prowl-push-dev.onevcat.workers.dev")
    #else
      nil
    #endif
  }()

  let baseURL: URL
  let session: URLSession

  init(baseURL: URL, session: URLSession = .shared) {
    self.baseURL = baseURL
    self.session = session
  }

  /// `nil` when no gateway is configured; the Host then sends nothing.
  static func configured(defaults: UserDefaults = .standard) -> Self? {
    let override = defaults.string(forKey: "remoteMirrorPushGatewayURL").flatMap(URL.init(string:))
    return (override ?? defaultBaseURL).map { Self(baseURL: $0) }
  }

  func push(token: String, collapseID: String, sealed: String) async -> MirrorPushGatewayResult {
    var request = URLRequest(url: baseURL.appending(path: "v1/push"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 15
    do {
      request.httpBody = try JSONEncoder().encode(["pushToken": token, "collapseID": collapseID, "sealed": sealed])
      let (_, response) = try await session.data(for: request)
      return Self.result(statusCode: (response as? HTTPURLResponse)?.statusCode)
    } catch {
      ProwlLogger("RemoteMirror").warning("Push gateway request failed", error: error)
      return .failed
    }
  }

  static func result(statusCode: Int?) -> MirrorPushGatewayResult {
    switch statusCode {
    case .some(200...299): .accepted
    case .some(410): .tokenGone
    default: .failed
    }
  }
}
