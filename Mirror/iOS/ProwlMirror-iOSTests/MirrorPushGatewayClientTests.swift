import CryptoKit
import Foundation
import Testing

@testable import ProwlMirror_iOS

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
    gateway.answer("POST /v1/tokens", 401, #"{"error":"unknown-installation"}"#)
    gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)

    #expect(try await client().createToken(apnsToken: "ab", environment: .production) == "push-1")
    #expect(gateway.routes().filter { $0 == "POST /v1/installations" }.count == 2)
    #expect(memory.current == MirrorPushInstallation(keyID: "key-2", installationID: "i2"))
  }

  @Test func anExpiredChallengeIsRetriedWithTheSameInstallation() async throws {
    gateway.answer("DELETE /v1/tokens/push-1", 401, #"{"error":"invalid-challenge"}"#)
    gateway.answer("DELETE /v1/tokens/push-1", 204)
    try await client().deleteToken("push-1")
    #expect(gateway.routes().filter { $0 == "POST /v1/installations" }.count == 1)
    #expect(memory.current?.installationID == "i1")
    let deletes = gateway.requests.filter { $0.httpMethod == "DELETE" }
    #expect(deletes.map { $0.value(forHTTPHeaderField: "X-Prowl-Installation") } == ["i1", "i1"])
  }

  @Test func anInvalidAssertionKeepsTheInstallation() async throws {
    gateway.answer("PUT /v1/tokens/push-1", 401, #"{"error":"invalid-assertion"}"#)
    await #expect(throws: MirrorPushGatewayError.refused(status: 401)) {
      try await client().updateToken("push-1", apnsToken: "ab")
    }
    #expect(memory.current?.installationID == "i1")
    #expect(gateway.routes().filter { $0 == "POST /v1/installations" }.count == 1)
  }

  @Test func aRequestThatIsNoLongerAllowedIsNotSent() async throws {
    await #expect(throws: MirrorPushGatewayError.superseded) {
      try await client().createToken(apnsToken: "ab", environment: .production, allowed: { false })
    }
    #expect(gateway.requests.isEmpty)
  }

  @Test func aSecond401IsAnError() async throws {
    gateway.answer("POST /v1/tokens", 401, #"{"error":"unknown-installation"}"#)
    gateway.answer("POST /v1/tokens", 401, #"{"error":"unknown-installation"}"#)

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

  @Test(.timeLimit(.minutes(1))) func requestsReachTheGatewayOneAfterAnother() async throws {
    gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-2"}"#)
    gateway.hold("POST /v1/tokens")
    let client = client()
    async let first = client.createToken(apnsToken: "ab", environment: .production)
    #expect(await eventually { gateway.isWaiting("POST /v1/tokens") })
    async let second = client.createToken(apnsToken: "cd", environment: .production)
    // The second request may not even take its challenge before the first one is answered.
    for _ in 0..<200 { await Task.yield() }
    #expect(gateway.routes().filter { $0 == "POST /v1/challenge" }.count == 2)

    gateway.release("POST /v1/tokens")
    #expect(try await [first, second] == ["push-1", "push-2"])
    #expect(gateway.routes().filter { $0 == "POST /v1/installations" }.count == 1)
  }

  @Test func aLostAppAttestKeyIsReplacedOnce() async throws {
    let saved = MirrorPushInstallation(keyID: "old-key", installationID: "i-old")
    let memory = MemoryStorage(saved)
    attest.lostKeys = ["old-key"]
    gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    let client = MirrorPushGatewayClient(
      baseURL: URL(string: "https://gateway.test")!, attest: attest, storage: memory.storage, send: gateway.send)

    #expect(try await client.createToken(apnsToken: "ab", environment: .production) == "push-1")
    #expect(memory.current == MirrorPushInstallation(keyID: "key-1", installationID: "i1"))
    let tokens = try #require(gateway.requests.last)
    #expect(tokens.value(forHTTPHeaderField: "X-Prowl-Installation") == "i1")
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
