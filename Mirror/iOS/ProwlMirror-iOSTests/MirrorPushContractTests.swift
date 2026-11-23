import CryptoKit
import Foundation
import Testing
import UserNotifications

@testable import ProwlMirror_iOS

/// The phone's side of the Mirror push contract. The Host tests the same file
/// (`Mirror/Fixtures/push/contract.json`), and the gateway keeps a copy of it.
struct MirrorPushContractTests {
  nonisolated(unsafe) static let contract: [String: Any] = {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Mirror/Fixtures/push/contract.json")
    let data = try! Data(contentsOf: url)
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
  }()

  private var messages: [String: Any] { Self.contract["messages"] as! [String: Any] }
  private var crypto: [String: String] { Self.contract["crypto"] as! [String: String] }
  private var content: [String: Any] { Self.contract["content"] as! [String: Any] }
  private var gateway: [String: Any] { Self.contract["gateway"] as! [String: Any] }

  private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

  private func sameJSON(_ data: Data, _ expected: Any) throws -> Bool {
    (try JSONSerialization.jsonObject(with: data) as? NSObject)?.isEqual(expected) == true
  }

  private static func bytes(_ hex: String) -> Data {
    Data(stride(from: 0, to: hex.count, by: 2).map { offset in
      let start = hex.index(hex.startIndex, offsetBy: offset)
      return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    })
  }

  private var key: SymmetricKey {
    MirrorPushCrypto.key(deviceSecret: Self.bytes(crypto["deviceSecretHex"]!), hostID: UUID(uuidString: crypto["hostID"]!)!)
  }

  @Test func pushControlsEncodeAndDecodeAsTheContractSays() throws {
    let register = MirrorMessage.pushRegister(
      .init(pushToken: "Zm9vYmFyLXB1c2gtdG9rZW4tMDEyMzQ1Njc4OQ", kinds: ["blocked", "done"]))
    let status = MirrorMessage.pushStatus(.init(pushEnabled: true, pushAllowedByMac: false, registered: true))
    let gone = MirrorMessage.pushStatus(
      .init(pushEnabled: true, pushAllowedByMac: true, registered: false, tokenGone: true))
    let cases: [(String, MirrorMessage)] = [
      ("pushRegister", register), ("pushUnregister", .pushUnregister), ("pushStatus", status),
      ("pushStatusTokenGone", gone),
    ]
    for (name, message) in cases {
      let expected = try #require(messages[name])
      #expect(try sameJSON(JSONEncoder().encode(message), expected), "\(name)")
      let decoded = try JSONDecoder().decode(MirrorMessage.self, from: json(expected))
      #expect(try sameJSON(JSONEncoder().encode(decoded), expected), "\(name)")
    }
  }

  @Test func kindsAndCapabilityMatch() {
    #expect(MirrorPushKind.allCases.map(\.rawValue) == Self.contract["kinds"] as? [String])
    #expect(Self.contract["capability"] as? String == MirrorPushContract.capability)
  }

  @Test func theVectorOpens() throws {
    #expect(key.withUnsafeBytes { Data($0) } == Self.bytes(crypto["keyHex"]!))
    let sealed = crypto["sealed"]!
    #expect(MirrorPushCrypto.hostID(ofSealed: sealed) == UUID(uuidString: crypto["hostID"]!))
    #expect(try MirrorPushCrypto.open(sealed, key: key) == Data(crypto["plaintext"]!.utf8))
    #expect(MirrorPushCrypto.collapseID(paneID: UUID(uuidString: crypto["paneID"]!)!, key: key) == crypto["collapseID"])
  }

  @Test func contentDecodesAsTheContractSays() throws {
    let complete = try MirrorPushContent.decode(json(content["complete"]!))
    #expect(complete.kind == .blocked && complete.stateChangedAt == "2026-11-22T05:31:31Z")
    let untimed = try MirrorPushContent.decode(json(content["withoutTimestamp"]!))
    #expect(untimed.kind == .done && untimed.stateChangedAt == nil)
    #expect(throws: MirrorPushCrypto.Failure.unsupportedVersion) {
      try MirrorPushContent.decode(json(content["unsupportedVersion"]!))
    }
  }

  /// What the gateway delivers, with a `sealed` the Host made, opens in the extension; the
  /// fallback keys that the gateway names exist in the app's strings.
  @Test func theGatewayPayloadOpensAndItsFallbackKeysExist() throws {
    let hostID = UUID(uuidString: crypto["hostID"]!)!
    let sent = try JSONSerialization.data(withJSONObject: content["complete"]!)
    let sealed = try MirrorPushCrypto.seal(sent, key: key, hostID: hostID)
    var payload = try #require(gateway["apnsPayload"] as? [String: Any])
    payload["sealed"] = sealed

    let opened = try #require(MirrorPushNotification.open(userInfo: payload, key: { $0 == hostID ? key : nil }))
    #expect(opened.content.title == "Prowl · main")

    let alert = try #require(((payload["aps"] as? [String: Any])?["alert"]) as? [String: String])
    for key in alert.values {
      #expect(Bundle.main.localizedString(forKey: key, value: "missing", table: nil) != "missing", "\(key)")
    }
    #expect((payload["aps"] as? [String: Any])?["mutable-content"] as? Int == 1)
  }

  @Test func theGatewayAddressMatches() {
    #expect(MirrorPushContract.gatewayURL.absoluteString == gateway["url"] as? String)
  }

  @Test func managementRequestsFollowTheContract() async throws {
    let management = try #require(gateway["management"] as? [String: Any])
    let headers = try #require(management["headers"] as? [String])
    for code in try #require(management["renewInstallationOn401"] as? [String]) {
      let (fake, memory) = (FakeGateway(), MemoryStorage())
      fake.answer("DELETE /v1/tokens/t", 401, #"{"error":"\#(code)"}"#)
      fake.answer("DELETE /v1/tokens/t", 204)
      try await client(fake, memory).deleteToken("t")
      #expect(memory.current?.installationID == "i2", "\(code) renews the installation")
    }
    for code in try #require(management["retryChallengeOn401"] as? [String]) {
      let (fake, memory) = (FakeGateway(), MemoryStorage())
      fake.answer("DELETE /v1/tokens/t", 401, #"{"error":"\#(code)"}"#)
      fake.answer("DELETE /v1/tokens/t", 204)
      try await client(fake, memory).deleteToken("t")
      #expect(memory.current?.installationID == "i1", "\(code) keeps the installation")
      let delete = try #require(fake.requests.last { $0.httpMethod == "DELETE" })
      #expect(headers.allSatisfy { delete.value(forHTTPHeaderField: $0) != nil })
    }
  }

  private func client(_ fake: FakeGateway, _ memory: MemoryStorage) -> MirrorPushGatewayClient {
    MirrorPushGatewayClient(
      baseURL: URL(string: "https://gateway.test")!, attest: FakeAttest(), storage: memory.storage, send: fake.send)
  }
}
