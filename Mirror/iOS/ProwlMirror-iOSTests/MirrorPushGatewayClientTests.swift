import CryptoKit
import Foundation
import Testing

@testable import ProwlMirror_iOS

private final class FakeAttest: MirrorAppAttesting, @unchecked Sendable {
  let isSupported: Bool
  private let lock = NSLock()
  private var keys = 0
  private(set) var assertedHashes: [Data] = []

  init(isSupported: Bool = true) { self.isSupported = isSupported }

  func generateKey() async throws -> String {
    lock.withLock {
      keys += 1
      return "key-\(keys)"
    }
  }

  func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data { Data("attest:\(keyID)".utf8) }

  func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
    lock.withLock { assertedHashes.append(clientDataHash) }
    return Data("assert:\(keyID)".utf8)
  }
}

/// Answers by "METHOD path"; challenges are numbered so each request can be matched.
private final class FakeGateway: @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [String: [(Int, String)]] = [:]
  private var challenges = 0
  private var installations = 0
  private(set) var requests: [URLRequest] = []

  func answer(_ route: String, _ status: Int, _ body: String = "{}") {
    lock.withLock { answers[route, default: []].append((status, body)) }
  }

  func routes() -> [String] {
    lock.withLock { requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } }
  }

  var send: MirrorPushGatewayClient.Send {
    { request in
      let (status, body, headers): (Int, String, [String: String]) = self.lock.withLock {
        self.requests.append(request)
        let route = "\(request.httpMethod ?? "") \(request.url?.path() ?? "")"
        if route == "POST /v1/challenge" {
          self.challenges += 1
          return (200, #"{"challenge":"c\#(self.challenges)"}"#, [:])
        }
        if route == "POST /v1/installations", self.answers[route]?.isEmpty ?? true {
          self.installations += 1
          return (201, #"{"installationID":"i\#(self.installations)"}"#, [:])
        }
        guard var queue = self.answers[route], !queue.isEmpty else { return (500, "{}", [:]) }
        let next = queue.removeFirst()
        self.answers[route] = queue
        return (next.0, next.1, next.0 == 429 ? ["Retry-After": "7"] : [:])
      }
      let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
      return (Data(body.utf8), response)
    }
  }
}

private final class MemoryStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var value: MirrorPushInstallation?
  var current: MirrorPushInstallation? { lock.withLock { value } }
  var storage: MirrorPushInstallationStorage {
    MirrorPushInstallationStorage(
      load: { self.lock.withLock { self.value } }, save: { new in self.lock.withLock { self.value = new } })
  }
}

struct MirrorPushGatewayClientTests {
  private let attest = FakeAttest()
  private let gateway = FakeGateway()
  private let memory = MemoryStorage()

  private func client(attest: FakeAttest? = nil) -> MirrorPushGatewayClient {
    MirrorPushGatewayClient(
      baseURL: URL(string: "https://gateway.test")!, attest: attest ?? self.attest, storage: memory.storage,
      send: gateway.send)
  }

  @Test func attestsOnceThenSignsEachRequestOverMethodPathChallengeAndBody() async throws {
    gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-2"}"#)
    let client = client()

    #expect(try await client.createToken(apnsToken: "ab", environment: .development) == "push-1")
    #expect(try await client.createToken(apnsToken: "cd", environment: .production) == "push-2")

    #expect(
      gateway.routes() == [
        "POST /v1/challenge", "POST /v1/installations", "POST /v1/challenge", "POST /v1/tokens",
        "POST /v1/challenge", "POST /v1/tokens",
      ])
    #expect(memory.current == MirrorPushInstallation(keyID: "key-1", installationID: "i1"))

    let install = try #require(gateway.requests[1].httpBody)
    let installBody = try JSONDecoder().decode([String: String].self, from: install)
    #expect(installBody["keyID"] == "key-1")
    #expect(installBody["challenge"] == "c1")
    #expect(installBody["attestationObject"] == Data("attest:key-1".utf8).base64EncodedString())

    let tokens = gateway.requests[3]
    #expect(tokens.value(forHTTPHeaderField: "X-Prowl-Installation") == "i1")
    #expect(tokens.value(forHTTPHeaderField: "X-Prowl-Challenge") == "c2")
    #expect(tokens.value(forHTTPHeaderField: "X-Prowl-Assertion") == Data("assert:key-1".utf8).base64EncodedString())
    let body = try #require(tokens.httpBody)
    #expect(try JSONDecoder().decode([String: String].self, from: body) == ["apnsToken": "ab", "environment": "development"])
    let clientData = Data("POST /v1/tokens\nc2\n".utf8) + body
    #expect(attest.assertedHashes.first == Data(SHA256.hash(data: clientData)))
  }

  @Test func updatesAndDeletesTokensByPath() async throws {
    gateway.answer("PUT /v1/tokens/push-1", 204)
    gateway.answer("DELETE /v1/tokens/push-1", 204)
    gateway.answer("DELETE /v1/tokens/push-2", 404)
    let client = client()

    try await client.updateToken("push-1", apnsToken: "ef")
    try await client.deleteToken("push-1")
    try await client.deleteToken("push-2")

    let put = try #require(gateway.requests.first { $0.httpMethod == "PUT" })
    #expect(try JSONDecoder().decode([String: String].self, from: #require(put.httpBody)) == ["apnsToken": "ef"])
    let delete = try #require(gateway.requests.first { $0.httpMethod == "DELETE" })
    #expect(delete.httpBody == nil)
    let deleteHash = Data(SHA256.hash(data: Data("DELETE /v1/tokens/push-1\nc3\n".utf8)))
    #expect(attest.assertedHashes.contains(deleteHash))
  }

  @Test func a401RenewsTheInstallationOnceAndRetries() async throws {
    gateway.answer("POST /v1/tokens", 401)
    gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)

    #expect(try await client().createToken(apnsToken: "ab", environment: .production) == "push-1")
    #expect(gateway.routes().filter { $0 == "POST /v1/installations" }.count == 2)
    #expect(memory.current == MirrorPushInstallation(keyID: "key-2", installationID: "i2"))
  }

  @Test func aSecond401IsAnError() async throws {
    gateway.answer("POST /v1/tokens", 401)
    gateway.answer("POST /v1/tokens", 401)

    await #expect(throws: MirrorPushGatewayError.refused(status: 401)) {
      try await client().createToken(apnsToken: "ab", environment: .production)
    }
    #expect(gateway.routes().filter { $0 == "POST /v1/tokens" }.count == 2)
  }

  @Test func mapsLimitsAndRefusals() async throws {
    gateway.answer("POST /v1/tokens", 409, #"{"error":"too-many-tokens"}"#)
    gateway.answer("POST /v1/tokens", 429)
    gateway.answer("PUT /v1/tokens/push-1", 403)
    gateway.answer("POST /v1/tokens", 201, #"{"other":"x"}"#)
    let client = client()

    await #expect(throws: MirrorPushGatewayError.tooManyTokens) {
      try await client.createToken(apnsToken: "ab", environment: .production)
    }
    await #expect(throws: MirrorPushGatewayError.rateLimited(retryAfter: 7)) {
      try await client.createToken(apnsToken: "ab", environment: .production)
    }
    await #expect(throws: MirrorPushGatewayError.refused(status: 403)) {
      try await client.updateToken("push-1", apnsToken: "ab")
    }
    await #expect(throws: MirrorPushGatewayError.invalidResponse) {
      try await client.createToken(apnsToken: "ab", environment: .production)
    }
  }

  @Test func aRefusedAttestationKeepsNoInstallation() async throws {
    gateway.answer("POST /v1/installations", 401, #"{"error":"invalid-attestation"}"#)

    await #expect(throws: MirrorPushGatewayError.refused(status: 401)) {
      try await client().createToken(apnsToken: "ab", environment: .production)
    }
    #expect(memory.current == nil)
    #expect(!gateway.routes().contains("POST /v1/tokens"))
  }

  @Test func withoutAppAttestNothingIsSent() async throws {
    await #expect(throws: MirrorPushGatewayError.attestUnsupported) {
      try await client(attest: FakeAttest(isSupported: false)).createToken(apnsToken: "ab", environment: .production)
    }
    #expect(gateway.requests.isEmpty)
  }
}

struct MirrorAPNsEnvironmentTests {
  private func profile(_ entitlements: String) -> Data {
    Data(
      """
      garbage-before\u{0}\u{1}<?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict><key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>\u{0}after
      """.utf8)
  }

  @Test func readsTheEnvironmentFromTheEmbeddedProfile() {
    #expect(
      MirrorAPNsEnvironment.environment(
        fromProfile: profile("<key>aps-environment</key><string>development</string>")) == .development)
    #expect(
      MirrorAPNsEnvironment.environment(
        fromProfile: profile("<key>aps-environment</key><string>production</string>")) == .production)
    #expect(MirrorAPNsEnvironment.environment(fromProfile: profile("")) == .production)
    #expect(MirrorAPNsEnvironment.environment(fromProfile: nil) == .production)
    #expect(MirrorAPNsEnvironment.environment(fromProfile: Data("not a profile".utf8)) == .production)
  }
}
