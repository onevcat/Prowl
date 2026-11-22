import CryptoKit
import Foundation
import Testing
import UserNotifications

@testable import ProwlMirror_iOS

/// The vector in `docs/remote-mirror-wire.md` ("Push content encryption"), also checked by the
/// Host tests and computed independently with Node's crypto.
struct MirrorPushCryptoTests {
  private let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  private let paneID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
  private let sealed = "ERERESIiMzNERFVVVVVVVQABAgMEBQYHCAkKC822FCs5oi5CZcjy+b8H7gVLmwX1v69/XSq/EKCoVU+w"
  private var key: SymmetricKey { MirrorPushCrypto.key(deviceSecret: Data(repeating: 7, count: 32), hostID: hostID) }

  @Test func opensTheWireVector() throws {
    #expect(
      key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        == "1e7f1b8f0c110534f475d3c51bdf3c98a0fb10d5ad60aa72cc4add9f1c702aa1")
    #expect(MirrorPushCrypto.hostID(ofSealed: sealed) == hostID)
    #expect(try MirrorPushCrypto.open(sealed, key: key) == Data(#"{"hello":"push"}"#.utf8))
    #expect(MirrorPushCrypto.collapseID(paneID: paneID, key: key) == "6O3nw3oYaPm_Beb9LXEOnA")
  }

  @Test func refusesAnotherKeyAndChangedBytes() throws {
    let otherKey = MirrorPushCrypto.key(deviceSecret: Data(repeating: 8, count: 32), hostID: hostID)
    #expect(throws: CryptoKitError.self) { try MirrorPushCrypto.open(sealed, key: otherKey) }

    var bytes = try #require(Data(base64Encoded: sealed))
    bytes[bytes.count - 1] ^= 1
    #expect(throws: CryptoKitError.self) { try MirrorPushCrypto.open(bytes.base64EncodedString(), key: key) }
  }

  @Test func refusesMalformedValues() {
    for value in ["", "not base64", Data(repeating: 1, count: 16).base64EncodedString(),
      Data(repeating: 1, count: 30).base64EncodedString()]
    {
      #expect(throws: MirrorPushCrypto.Failure.malformed) { try MirrorPushCrypto.open(value, key: key) }
    }
    #expect(MirrorPushCrypto.hostID(ofSealed: "not base64") == nil)
    #expect(MirrorPushCrypto.hostID(ofSealed: Data(repeating: 1, count: 15).base64EncodedString()) == nil)
  }

  @Test func decodesContentOfVersionOneOnly() throws {
    let content = MirrorPushContent(
      kind: .blocked, paneID: paneID, title: "Prowl · main", body: "An agent needs your attention",
      stateChangedAt: nil)
    let sealed = try MirrorPushCrypto.seal(JSONEncoder().encode(content), key: key, hostID: hostID)
    #expect(try MirrorPushContent.decode(MirrorPushCrypto.open(sealed, key: key)) == content)

    let newer = Data(
      #"{"v":2,"kind":"done","paneID":"\#(paneID.uuidString)","title":"t","body":"b"}"#.utf8)
    #expect(throws: MirrorPushCrypto.Failure.unsupportedVersion) { try MirrorPushContent.decode(newer) }
    #expect(throws: DecodingError.self) { try MirrorPushContent.decode(Data(#"{"v":1}"#.utf8)) }
  }
}

@Suite(.serialized)
struct MirrorPushKeyStoreTests {
  @Test func savesReplacesAndRemovesTheKeyOfAHost() throws {
    let hostID = UUID()
    defer { try? MirrorPushKeyStore.remove(hostID: hostID) }
    #expect(try MirrorPushKeyStore.load(hostID: hostID) == nil)

    let first = SymmetricKey(size: .bits256)
    try MirrorPushKeyStore.save(first, hostID: hostID)
    #expect(try MirrorPushKeyStore.load(hostID: hostID) == first)

    let second = SymmetricKey(size: .bits256)
    try MirrorPushKeyStore.save(second, hostID: hostID)
    #expect(try MirrorPushKeyStore.load(hostID: hostID) == second)

    try MirrorPushKeyStore.remove(hostID: hostID)
    #expect(try MirrorPushKeyStore.load(hostID: hostID) == nil)
    try MirrorPushKeyStore.remove(hostID: hostID)
  }

  @Test func usesTheSharedGroup() {
    #expect(MirrorPushKeyStore.accessGroup?.hasSuffix("com.onevcat.prowl.mirror.shared") == true)
  }
}

struct MirrorPushNotificationTests {
  private let hostID = UUID()
  private let paneID = UUID()
  private let key = SymmetricKey(size: .bits256)

  private func sealed(_ kind: MirrorPushKind, key: SymmetricKey? = nil) throws -> String {
    let content = MirrorPushContent(
      kind: kind, paneID: paneID, title: "Prowl · main", body: "Allow rm -rf build?", stateChangedAt: nil)
    return try MirrorPushCrypto.seal(JSONEncoder().encode(content), key: key ?? self.key, hostID: hostID)
  }

  private func keys(_ id: UUID) -> SymmetricKey? { id == hostID ? key : nil }

  @Test func showsGenericTextByKindAndKeepsTheRouteForTheTap() throws {
    for (kind, body) in [(MirrorPushKind.blocked, "An agent needs your attention"), (.done, "An agent finished")] {
      let opened = try #require(MirrorPushNotification.open(userInfo: ["sealed": sealed(kind)], key: keys))
      let content = UNMutableNotificationContent()
      content.title = "fallback title"
      content.userInfo = ["sealed": try sealed(kind), "aps": ["mutable-content": 1]]
      MirrorPushNotification.apply(opened, to: content)

      #expect(content.title == "Prowl")
      #expect(content.body == body)
      #expect(!content.body.contains("rm -rf"))
      #expect(content.threadIdentifier == hostID.uuidString)
      #expect(content.targetContentIdentifier == paneID.uuidString)
      #expect(content.userInfo["sealed"] == nil)
      #expect(content.userInfo["hostID"] as? String == hostID.uuidString)
      #expect(content.userInfo["paneID"] as? String == paneID.uuidString)
      #expect(content.userInfo["kind"] as? String == kind.rawValue)
      #expect(content.userInfo["aps"] != nil)
    }
  }

  @Test func leavesTheFallbackWhenThePushCannotBeOpened() throws {
    let otherKey = SymmetricKey(size: .bits256)
    #expect(MirrorPushNotification.open(userInfo: [:], key: keys) == nil)
    #expect(MirrorPushNotification.open(userInfo: ["sealed": 42], key: keys) == nil)
    #expect(MirrorPushNotification.open(userInfo: ["sealed": "corrupt"], key: keys) == nil)
    #expect(MirrorPushNotification.open(userInfo: ["sealed": try sealed(.blocked)], key: { _ in nil }) == nil)
    #expect(MirrorPushNotification.open(userInfo: ["sealed": try sealed(.blocked, key: otherKey)], key: keys) == nil)
  }

  @Test func theAppShipsTheGatewayFallbackStrings() {
    #expect(String(localized: "MIRROR_PUSH_TITLE") == "Prowl")
    #expect(String(localized: "MIRROR_PUSH_FALLBACK") == "An agent on your Mac has an update")
  }
}
