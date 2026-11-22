import CryptoKit
import Foundation
import Testing
import UserNotifications

@testable import ProwlMirror_iOS

/// Failure paths of opening; the shared vector itself is in `MirrorPushContractTests`.
struct MirrorPushCryptoTests {
  private let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  private let paneID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
  private let sealed = "ERERESIiMzNERFVVVVVVVQABAgMEBQYHCAkKC822FCs5oi5CZcjy+b8H7gVLmwX1v69/XSq/EKCoVU+w"
  private var key: SymmetricKey { MirrorPushCrypto.key(deviceSecret: Data(repeating: 7, count: 32), hostID: hostID) }

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

  @Test func showDetailsIsStoredInTheSharedGroup() throws {
    let before = MirrorPushKeyStore.showsDetails
    defer { try? MirrorPushKeyStore.setShowsDetails(before) }
    try MirrorPushKeyStore.setShowsDetails(true)
    #expect(MirrorPushKeyStore.showsDetails)
    try MirrorPushKeyStore.setShowsDetails(false)
    #expect(!MirrorPushKeyStore.showsDetails)
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
      MirrorPushNotification.apply(opened, to: content, showsDetails: false)

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

  @Test func showDetailsUsesTheHostsTitleAndText() throws {
    let opened = try #require(MirrorPushNotification.open(userInfo: ["sealed": sealed(.blocked)], key: keys))
    let content = UNMutableNotificationContent()
    MirrorPushNotification.apply(opened, to: content, showsDetails: true)
    #expect(content.title == "Prowl · main")
    #expect(content.body == "Allow rm -rf build?")
    #expect(content.userInfo["paneID"] as? String == paneID.uuidString)

    let untitled = MirrorPushNotification.Opened(
      hostID: hostID,
      content: MirrorPushContent(kind: .done, paneID: paneID, title: "", body: "x", stateChangedAt: nil))
    MirrorPushNotification.apply(untitled, to: content, showsDetails: true)
    #expect(content.title == "Prowl")
    #expect(content.body == "An agent finished")
  }

  @Test func leavesTheFallbackWhenThePushCannotBeOpened() throws {
    let otherKey = SymmetricKey(size: .bits256)
    #expect(MirrorPushNotification.open(userInfo: [:], key: keys) == nil)
    #expect(MirrorPushNotification.open(userInfo: ["sealed": 42], key: keys) == nil)
    #expect(MirrorPushNotification.open(userInfo: ["sealed": "corrupt"], key: keys) == nil)
    #expect(MirrorPushNotification.open(userInfo: ["sealed": try sealed(.blocked)], key: { _ in nil }) == nil)
    #expect(MirrorPushNotification.open(userInfo: ["sealed": try sealed(.blocked, key: otherKey)], key: keys) == nil)
  }

  @Test func saysWhyAPushKeepsTheFallback() throws {
    let otherKey = SymmetricKey(size: .bits256)
    let future = try MirrorPushCrypto.seal(Data(#"{"v":2,"kind":"blocked"}"#.utf8), key: key, hostID: hostID)
    let cases: [([AnyHashable: Any], MirrorPushNotification.Failure)] = [
      ([:], .malformed),
      (["sealed": "corrupt"], .malformed),
      (["sealed": try sealed(.blocked)], .noKey),
      (["sealed": try sealed(.blocked, key: otherKey)], .cannotOpen),
      (["sealed": future], .unsupportedContent),
    ]
    for (index, (userInfo, expected)) in cases.enumerated() {
      let lookup: (UUID) -> SymmetricKey? = { id in expected == .noKey ? nil : self.keys(id) }
      guard case .failure(let failure) = MirrorPushNotification.read(userInfo: userInfo, key: lookup) else {
        Issue.record("Case \(index) opened")
        continue
      }
      #expect(failure == expected, "case \(index)")
    }
  }

  @Test func theAppShipsTheGatewayFallbackStrings() {
    #expect(String(localized: "MIRROR_PUSH_TITLE") == "Prowl")
    #expect(String(localized: "MIRROR_PUSH_FALLBACK") == "An agent on your Mac has an update")
  }
}
