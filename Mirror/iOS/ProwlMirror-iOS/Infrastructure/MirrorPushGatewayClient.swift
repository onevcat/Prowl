import CryptoKit
import DeviceCheck
import Foundation

/// The APNs environment of this build, which the gateway needs to reach the device token.
nonisolated enum MirrorAPNsEnvironment: String, Sendable {
  case development, production

  /// Development builds embed a provisioning profile with `aps-environment`; App Store and
  /// TestFlight builds embed none and always use production.
  static var current: Self {
    let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
    return environment(fromProfile: url.flatMap { try? Data(contentsOf: $0) })
  }

  static func environment(fromProfile profile: Data?) -> Self {
    guard let profile,
      let start = profile.range(of: Data("<?xml".utf8)),
      let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
      let plist = try? PropertyListSerialization.propertyList(
        from: profile[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
      let entitlements = plist["Entitlements"] as? [String: Any],
      let value = entitlements["aps-environment"] as? String
    else { return .production }
    return Self(rawValue: value) ?? .production
  }
}

/// App Attest, behind a seam for tests.
nonisolated protocol MirrorAppAttesting: Sendable {
  var isSupported: Bool { get }
  func generateKey() async throws -> String
  func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
  func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

nonisolated struct DeviceAppAttest: MirrorAppAttesting {
  var isSupported: Bool { DCAppAttestService.shared.isSupported }
  func generateKey() async throws -> String { try await DCAppAttestService.shared.generateKey() }
  func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
    try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
  }
  func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
    try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
  }
}

/// The App Attest key and the gateway's record of it. One per app install.
nonisolated struct MirrorPushInstallation: Codable, Equatable, Sendable {
  let keyID: String
  let installationID: String
}

nonisolated struct MirrorPushInstallationStorage: Sendable {
  var load: @Sendable () -> MirrorPushInstallation?
  var save: @Sendable (MirrorPushInstallation?) -> Void

  static let keychain = Self(
    load: { try? MirrorCredentialVault.load(MirrorPushInstallation.self, account: "push-installation") },
    save: { value in
      if let value {
        try? MirrorCredentialVault.save(value, account: "push-installation")
      } else {
        try? MirrorCredentialVault.remove(account: "push-installation")
      }
    })
}

nonisolated enum MirrorPushGatewayError: Error, Equatable {
  /// This device cannot attest (simulator, or App Attest off).
  case attestUnsupported
  case rateLimited(retryAfter: Int?)
  case tooManyTokens
  case refused(status: Int)
  case invalidResponse
}

/// The phone's side of the push gateway (docs-ai 095, `prowl-push-gateway` README "Phone API").
/// Every management request carries an App Attest assertion over
/// `"<METHOD> <PATH>\n<challenge>\n<body>"`; a push token never manages anything.
actor MirrorPushGatewayClient {
  typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  private let baseURL: URL
  private let attest: any MirrorAppAttesting
  private let storage: MirrorPushInstallationStorage
  private let send: Send
  private var installing: Task<MirrorPushInstallation, any Error>?

  init(
    baseURL: URL = MirrorPushGatewayAddress.url, attest: any MirrorAppAttesting = DeviceAppAttest(),
    storage: MirrorPushInstallationStorage = .keychain, send: @escaping Send = MirrorPushGatewayClient.urlSession
  ) {
    self.baseURL = baseURL
    self.attest = attest
    self.storage = storage
    self.send = send
  }

  static let urlSession: Send = { request in
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw MirrorPushGatewayError.invalidResponse }
    return (data, http)
  }

  /// A new push token for this APNs token; the Host gets it with `pushRegister`.
  func createToken(apnsToken: String, environment: MirrorAPNsEnvironment) async throws -> String {
    let body = try JSONEncoder().encode(["apnsToken": apnsToken, "environment": environment.rawValue])
    let (data, status) = try await manage("POST", path: "/v1/tokens", body: body)
    switch status {
    case 201:
      guard let token = try? JSONDecoder().decode([String: String].self, from: data)["pushToken"] else {
        throw MirrorPushGatewayError.invalidResponse
      }
      return token
    case 409: throw MirrorPushGatewayError.tooManyTokens
    default: throw MirrorPushGatewayError.refused(status: status)
    }
  }

  /// Points an existing push token at a new APNs token.
  func updateToken(_ pushToken: String, apnsToken: String) async throws {
    let body = try JSONEncoder().encode(["apnsToken": apnsToken])
    let (_, status) = try await manage("PUT", path: "/v1/tokens/\(pushToken)", body: body)
    guard status == 204 else { throw MirrorPushGatewayError.refused(status: status) }
  }

  /// Deletes a push token, so no Host can use it again; an unknown token is already gone.
  func deleteToken(_ pushToken: String) async throws {
    let (_, status) = try await manage("DELETE", path: "/v1/tokens/\(pushToken)", body: nil)
    guard status == 204 || status == 404 else { throw MirrorPushGatewayError.refused(status: status) }
  }

  // MARK: Management

  /// Sends a management request. A `401` means the gateway no longer accepts this installation
  /// (deleted, or its counter moved on); the app attests a new key and tries once more.
  private func manage(_ method: String, path: String, body: Data?) async throws -> (Data, Int) {
    var renewed = false
    while true {
      let installation = try await installation()
      let challenge = try await challenge()
      let bodyText = body.map { String(decoding: $0, as: UTF8.self) } ?? ""
      let clientData = Data("\(method) \(path)\n\(challenge)\n\(bodyText)".utf8)
      let assertion = try await attest.generateAssertion(
        installation.keyID, clientDataHash: Data(SHA256.hash(data: clientData)))
      var request = request(method, path: path, body: body)
      request.setValue(installation.installationID, forHTTPHeaderField: "X-Prowl-Installation")
      request.setValue(challenge, forHTTPHeaderField: "X-Prowl-Challenge")
      request.setValue(assertion.base64EncodedString(), forHTTPHeaderField: "X-Prowl-Assertion")
      let (data, response) = try await send(request)
      if response.statusCode == 401, !renewed {
        renewed = true
        if storage.load() == installation { storage.save(nil) }
        continue
      }
      try Self.checkRateLimit(response)
      return (data, response.statusCode)
    }
  }

  private func installation() async throws -> MirrorPushInstallation {
    if let stored = storage.load() { return stored }
    if let installing { return try await installing.value }
    let task = Task { try await self.attestNewKey() }
    installing = task
    defer { installing = nil }
    let installation = try await task.value
    storage.save(installation)
    return installation
  }

  private func attestNewKey() async throws -> MirrorPushInstallation {
    guard attest.isSupported else { throw MirrorPushGatewayError.attestUnsupported }
    let keyID = try await attest.generateKey()
    let challenge = try await challenge()
    let attestation = try await attest.attestKey(keyID, clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8))))
    let body = try JSONEncoder().encode([
      "keyID": keyID, "attestationObject": attestation.base64EncodedString(), "challenge": challenge,
    ])
    let (data, response) = try await send(request("POST", path: "/v1/installations", body: body))
    try Self.checkRateLimit(response)
    guard response.statusCode == 201 else { throw MirrorPushGatewayError.refused(status: response.statusCode) }
    guard let id = try? JSONDecoder().decode([String: String].self, from: data)["installationID"] else {
      throw MirrorPushGatewayError.invalidResponse
    }
    return MirrorPushInstallation(keyID: keyID, installationID: id)
  }

  private func challenge() async throws -> String {
    let (data, response) = try await send(request("POST", path: "/v1/challenge", body: nil))
    try Self.checkRateLimit(response)
    guard response.statusCode == 200,
      let challenge = try? JSONDecoder().decode([String: String].self, from: data)["challenge"]
    else { throw MirrorPushGatewayError.refused(status: response.statusCode) }
    return challenge
  }

  private func request(_ method: String, path: String, body: Data?) -> URLRequest {
    var request = URLRequest(url: baseURL.appending(path: path))
    request.httpMethod = method
    request.httpBody = body
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    return request
  }

  private static func checkRateLimit(_ response: HTTPURLResponse) throws {
    guard response.statusCode == 429 else { return }
    throw MirrorPushGatewayError.rateLimited(
      retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
  }
}
