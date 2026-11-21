import CryptoKit
import Foundation
import Testing

@testable import Prowl

struct MirrorPushPlannerTests {
  typealias Device = MirrorPushPlanner.Device

  private let pane = UUID()
  private let deviceID = UUID()
  private let start = ContinuousClock.now

  private func device(online: Bool = false, kinds: Set<MirrorPushKind> = [.blocked, .done]) -> Device {
    .init(id: deviceID, kinds: kinds, isOnline: online)
  }

  private func away() -> MirrorPushPlanner {
    var planner = MirrorPushPlanner()
    _ = planner.presenceChanged(to: false, devices: [])
    return planner
  }

  private func blocked() -> [MirrorPushPlanner.Push] { [.init(deviceID: deviceID, paneID: pane, kind: .blocked)] }

  @Test func blockedWhileAwayAndOfflineIsPushedAtOnce() {
    var planner = away()
    _ = planner.paneChanged(pane, to: .working, at: start, devices: [device()])
    #expect(planner.paneChanged(pane, to: .blocked, at: start, devices: [device()]) == blocked())
  }

  @Test func blockedWhilePresentIsHeldAndSentOnceWhenTheUserLeaves() {
    var planner = MirrorPushPlanner()
    #expect(planner.paneChanged(pane, to: .blocked, at: start, devices: [device()]).isEmpty)
    #expect(planner.presenceChanged(to: false, devices: [device()]) == blocked())
    #expect(planner.presenceChanged(to: true, devices: [device()]).isEmpty)
    #expect(planner.presenceChanged(to: false, devices: [device()]).isEmpty)
  }

  @Test func blockedWhileTheDeviceIsOnlineIsSentWhenItGoesOfflineWhileAway() {
    var planner = away()
    #expect(planner.paneChanged(pane, to: .blocked, at: start, devices: [device(online: true)]).isEmpty)
    #expect(planner.deviceWentOffline(device()) == blocked())
    #expect(planner.deviceWentOffline(device()).isEmpty)
  }

  @Test func goingOfflineWhileTheUserIsPresentSendsNothingUntilTheUserLeaves() {
    var planner = MirrorPushPlanner()
    _ = planner.paneChanged(pane, to: .blocked, at: start, devices: [device(online: true)])
    #expect(planner.deviceWentOffline(device()).isEmpty)
    #expect(planner.presenceChanged(to: false, devices: [device()]) == blocked())
  }

  @Test func aHeldPromptThatClosedIsNotSentLate() {
    var planner = MirrorPushPlanner()
    _ = planner.paneChanged(pane, to: .blocked, at: start, devices: [device()])
    _ = planner.paneChanged(pane, to: .working, at: start, devices: [device()])
    #expect(planner.presenceChanged(to: false, devices: [device()]).isEmpty)
  }

  @Test func onlyTheLatestOpeningOfAPaneIsSentLate() {
    var planner = MirrorPushPlanner()
    _ = planner.paneChanged(pane, to: .blocked, at: start, devices: [device()])
    _ = planner.paneChanged(pane, to: .working, at: start, devices: [device()])
    _ = planner.paneChanged(pane, to: .blocked, at: start, devices: [device()])
    #expect(planner.presenceChanged(to: false, devices: [device()]) == blocked())
  }

  @Test func doneNeedsTenSecondsOfWorkingAndTheUserAway() {
    var planner = away()
    _ = planner.paneChanged(pane, to: .working, at: start, devices: [device()])
    #expect(planner.paneChanged(pane, to: .done, at: start.advanced(by: .seconds(9)), devices: [device()]).isEmpty)
    _ = planner.paneChanged(pane, to: .working, at: start, devices: [device()])
    #expect(
      planner.paneChanged(pane, to: .done, at: start.advanced(by: .seconds(10)), devices: [device()])
        == [.init(deviceID: deviceID, paneID: pane, kind: .done)])
    var present = MirrorPushPlanner()
    _ = present.paneChanged(pane, to: .working, at: start, devices: [device()])
    #expect(present.paneChanged(pane, to: .done, at: start.advanced(by: .seconds(60)), devices: [device()]).isEmpty)
    // `done` is never sent late.
    #expect(present.presenceChanged(to: false, devices: [device()]).isEmpty)
  }

  @Test func doneIsNotSentToAnOnlineDevice() {
    var planner = away()
    _ = planner.paneChanged(pane, to: .working, at: start, devices: [device(online: true)])
    #expect(
      planner.paneChanged(pane, to: .done, at: start.advanced(by: .seconds(30)), devices: [device(online: true)])
        .isEmpty)
  }

  @Test func kindsTheDeviceDidNotAskForAreNotSent() {
    var planner = away()
    #expect(planner.paneChanged(pane, to: .blocked, at: start, devices: [device(kinds: [.done])]).isEmpty)
    _ = planner.paneChanged(pane, to: .working, at: start, devices: [device(kinds: [.blocked])])
    #expect(
      planner.paneChanged(pane, to: .done, at: start.advanced(by: .seconds(30)), devices: [device(kinds: [.blocked])])
        .isEmpty)
  }

  @Test func aClosedPaneIsForgotten() {
    var planner = MirrorPushPlanner()
    _ = planner.paneChanged(pane, to: .blocked, at: start, devices: [device()])
    planner.paneRemoved(pane, at: start)
    #expect(planner.presenceChanged(to: false, devices: [device()]).isEmpty)
  }

  @Test func aShortDetectionMissDoesNotPushTheSamePromptAgain() {
    var planner = away()
    #expect(planner.paneChanged(pane, to: .blocked, at: start, devices: [device()]) == blocked())
    planner.paneRemoved(pane, at: start.advanced(by: .seconds(1)))
    #expect(planner.paneChanged(pane, to: .blocked, at: start.advanced(by: .seconds(3)), devices: [device()]).isEmpty)
    // A pane that stayed away longer is a new prompt.
    planner.paneRemoved(pane, at: start.advanced(by: .seconds(4)))
    #expect(
      planner.paneChanged(pane, to: .blocked, at: start.advanced(by: .seconds(40)), devices: [device()]) == blocked())
  }

  @Test func aDetectionMissKeepsTheWorkingTimeForDone() {
    var planner = away()
    _ = planner.paneChanged(pane, to: .working, at: start, devices: [device()])
    planner.paneRemoved(pane, at: start.advanced(by: .seconds(5)))
    #expect(
      planner.paneChanged(pane, to: .done, at: start.advanced(by: .seconds(12)), devices: [device()])
        == [.init(deviceID: deviceID, paneID: pane, kind: .done)])
  }

  @Test func reactivationHoldsAnOpenPromptThatWasNeverPushed() {
    var planner = MirrorPushPlanner()
    // Held while the user sat at the Mac; then the sender stopped (for example the listener
    // restarted) and starts again with the prompt still open.
    _ = planner.paneChanged(pane, to: .blocked, at: start, devices: [device()])
    planner.activate(states: [pane: .blocked], at: start, devices: [device()])
    #expect(planner.presenceChanged(to: false, devices: [device()]) == blocked())
    // Once pushed, a later start does not hold it again.
    _ = planner.presenceChanged(to: true, devices: [device()])
    planner.activate(states: [pane: .blocked], at: start, devices: [device()])
    #expect(planner.presenceChanged(to: false, devices: [device()]).isEmpty)
  }
}

struct MirrorPushCryptoTests {
  // The same vector was computed independently with Node's crypto (HKDF-SHA256,
  // ChaCha20-Poly1305, HMAC-SHA256); the iOS extension must produce it too.
  private let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  private let paneID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

  @Test func keySealAndCollapseIDMatchTheSharedVector() throws {
    let key = MirrorPushCrypto.key(deviceSecret: Data(repeating: 7, count: 32), hostID: hostID)
    #expect(
      key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        == "1e7f1b8f0c110534f475d3c51bdf3c98a0fb10d5ad60aa72cc4add9f1c702aa1")
    let nonce = try ChaChaPolyNonce.make(hex: "000102030405060708090a0b")
    #expect(
      try MirrorPushCrypto.seal(Data(#"{"hello":"push"}"#.utf8), key: key, hostID: hostID, nonce: nonce)
        == "ERERESIiMzNERFVVVVVVVQABAgMEBQYHCAkKC822FCs5oi5CZcjy+b8H7gVLmwX1v69/XSq/EKCoVU+w")
    #expect(MirrorPushCrypto.collapseID(paneID: paneID, key: key) == "6O3nw3oYaPm_Beb9LXEOnA")
  }

  @Test func gatewayStatusCodesMapToResults() {
    #expect(URLSessionMirrorPushGateway.result(statusCode: 202) == .accepted)
    #expect(URLSessionMirrorPushGateway.result(statusCode: 410) == .tokenGone)
    for code in [400, 429, 500, nil] { #expect(URLSessionMirrorPushGateway.result(statusCode: code) == .failed) }
  }
}

enum ChaChaPolyNonce {
  static func make(hex: String) throws -> ChaChaPoly.Nonce {
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      bytes.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    return try ChaChaPoly.Nonce(data: bytes)
  }
}
