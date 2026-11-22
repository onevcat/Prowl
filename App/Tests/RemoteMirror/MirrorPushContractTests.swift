import CryptoKit
import Foundation
import Testing

@testable import Prowl

/// The Host's side of the Mirror push contract. The iOS app tests the same file
/// (`Mirror/Fixtures/push/contract.json`), and the gateway keeps a copy of it.
struct MirrorPushContractTests {
  struct Malformed: Error {}

  static func contract() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Mirror/Fixtures/push/contract.json")
    guard let contract = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
      throw Malformed()
    }
    return contract
  }

  private func section<T>(_ name: String, as type: T.Type = [String: Any].self) throws -> T {
    guard let value = try Self.contract()[name] as? T else { throw Malformed() }
    return value
  }

  private var messages: [String: Any] { get throws { try section("messages") } }
  private var crypto: [String: String] { get throws { try section("crypto", as: [String: String].self) } }
  private var content: [String: Any] { get throws { try section("content") } }
  private var gateway: [String: Any] { get throws { try section("gateway") } }

  private func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }

  private func sameJSON(_ data: Data, _ expected: Any) throws -> Bool {
    let actual = try JSONSerialization.jsonObject(with: data)
    return (actual as? NSObject)?.isEqual(expected) == true
  }

  private static func bytes(_ hex: String) -> Data {
    Data(
      stride(from: 0, to: hex.count, by: 2).map { offset in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
      })
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
      let all = try messages
      let expected = try #require(all[name])
      #expect(try sameJSON(JSONEncoder().encode(message), expected), "\(name)")
      let decoded = try JSONDecoder().decode(MirrorMessage.self, from: json(expected))
      #expect(try sameJSON(JSONEncoder().encode(decoded), expected), "\(name)")
    }
  }

  @Test func kindsAndCapabilityMatch() throws {
    let contract = try Self.contract()
    #expect(MirrorPushKind.allCases.map(\.rawValue) == contract["kinds"] as? [String])
    #expect(contract["capability"] as? String == MirrorPushContract.capability)
  }

  @Test func keySealAndCollapseIDMatchTheVector() throws {
    let crypto = try crypto
    let value = { (name: String) throws -> String in try #require(crypto[name]) }
    let hostID = try #require(UUID(uuidString: value("hostID")))
    let paneID = try #require(UUID(uuidString: value("paneID")))
    let key = MirrorPushCrypto.key(deviceSecret: Self.bytes(try value("deviceSecretHex")), hostID: hostID)
    #expect(key.withUnsafeBytes { Data($0) } == Self.bytes(try value("keyHex")))
    #expect(MirrorPushCrypto.info == Data(try value("info").utf8))
    let nonce = try ChaChaPoly.Nonce(data: Self.bytes(try value("nonceHex")))
    let sealed = try MirrorPushCrypto.seal(Data(try value("plaintext").utf8), key: key, hostID: hostID, nonce: nonce)
    #expect(sealed == (try value("sealed")))
    #expect(MirrorPushCrypto.collapseID(paneID: paneID, key: key) == (try value("collapseID")))
  }

  @Test func contentEncodesAsTheContractSays() throws {
    let content = try content
    let complete = try #require(content["complete"] as? [String: Any])
    let paneText = try #require(complete["paneID"] as? String)
    let sent = MirrorPushContent(
      kind: .blocked, paneID: try #require(UUID(uuidString: paneText)),
      title: try #require(complete["title"] as? String), body: try #require(complete["body"] as? String),
      stateChangedAt: complete["stateChangedAt"] as? String)
    #expect(try sameJSON(JSONEncoder().encode(sent), complete))
    for name in ["complete", "withoutTimestamp"] {
      let example = try #require(content[name])
      #expect(throws: Never.self) { try MirrorPushContent.decode(json(example)) }
    }
    let newer = try #require(content["unsupportedVersion"])
    #expect(throws: MirrorPushCrypto.Failure.unsupportedVersion) { try MirrorPushContent.decode(json(newer)) }
  }

  /// The Host closes a connection whose `pushRegister` carries a token it does not accept, so
  /// its check must accept every token the gateway issues.
  @Test func theHostAcceptsTheGatewaysTokenFormat() throws {
    let gateway = try gateway
    let samples = try #require(gateway["pushTokenSamples"] as? [String: [String]])
    for token in try #require(samples["valid"]) { #expect(MirrorPushRegistration.isValidToken(token), "\(token)") }
    for token in try #require(samples["invalid"]) { #expect(!MirrorPushRegistration.isValidToken(token), "\(token)") }
  }

  @Test func gatewayRequestAndResultsMatch() throws {
    let gateway = try gateway
    #expect(URLSessionMirrorPushGateway.defaultBaseURL.absoluteString == gateway["url"] as? String)
    let request = try URLSessionMirrorPushGateway.pushRequest(
      baseURL: URLSessionMirrorPushGateway.defaultBaseURL, token: "t", collapseID: "c", sealed: "s")
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path() == gateway["pushPath"] as? String)
    let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
    #expect(body?.keys.sorted() == gateway["pushRequestKeys"] as? [String])

    let results = try #require(gateway["pushResults"] as? [String: String])
    for (code, expected) in results {
      let result = URLSessionMirrorPushGateway.result(statusCode: Int(code))
      #expect("\(result)" == expected, "status \(code)")
    }
    // No answer at all (network error) is a failure too, outside the gateway's contract.
    #expect(URLSessionMirrorPushGateway.result(statusCode: nil) == .failed)
  }
}
