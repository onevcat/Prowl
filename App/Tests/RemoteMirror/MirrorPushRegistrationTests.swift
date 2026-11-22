import Foundation
import Testing

@testable import Prowl

struct MirrorPushRegistrationTests {
  private static let token = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCdE"

  @Test func wireShapesMatchTheContract() throws {
    let register = try MirrorWire.decode(
      Data([0]) + Data(#"{"pushRegister":{"_0":{"pushToken":"\#(Self.token)","kinds":["blocked","done"]}}}"#.utf8))
    guard case .pushRegister(let payload) = register else {
      Issue.record("Expected pushRegister")
      return
    }
    #expect(payload.pushToken == Self.token && payload.kinds == ["blocked", "done"])
    #expect(try MirrorWire.decode(Data([0]) + Data(#"{"pushUnregister":{}}"#.utf8)).kind == .pushUnregister)
    let status = try MirrorWire.encode(.pushStatus(.init(pushEnabled: true, pushAllowedByMac: false, registered: true)))
    let json = try #require(
      try JSONSerialization.jsonObject(with: status.dropFirst(5)) as? [String: [String: [String: Bool]]])
    #expect(json["pushStatus"]?["_0"] == ["pushEnabled": true, "pushAllowedByMac": false, "registered": true])
  }

  @Test func tokensMustBeURLSafeBase64OfAPlausibleLength() {
    #expect(MirrorPushRegistration.isValidToken(Self.token))
    #expect(!MirrorPushRegistration.isValidToken("short"))
    #expect(!MirrorPushRegistration.isValidToken(String(repeating: "a", count: 257)))
    #expect(!MirrorPushRegistration.isValidToken("AbCdEfGhIjKlMnOp QrSt"))
    #expect(!MirrorPushRegistration.isValidToken("AbCdEfGhIjKlMnOp+/=="))
  }

  @Test func devicesSavedBeforePushKeepWorkingAndAllowPush() throws {
    let json = #"{"id":"00000000-0000-0000-0000-000000000001","name":"Phone","key":"BwcH","pairedAt":0}"#
    let device = try JSONDecoder().decode(MirrorPairedDevice.self, from: Data(json.utf8))
    #expect(device.push == nil)
    #expect(device.pushAllowedByMac == nil && device.isPushAllowedByMac)
  }

  @Test func unknownOrBrokenPushFieldsNeverMakeTheDeviceUnreadable() throws {
    let future = #"""
      {"id":"00000000-0000-0000-0000-000000000001","name":"Phone","key":"BwcH","pairedAt":0,
       "push":{"token":"\#(Self.token)","kinds":["blocked","someday"]},"pushAllowedByMac":false}
      """#
    let device = try JSONDecoder().decode(MirrorPairedDevice.self, from: Data(future.utf8))
    #expect(device.push?.kinds == [.blocked])
    #expect(device.isPushAllowedByMac == false)
    let broken = #"{"id":"00000000-0000-0000-0000-000000000001","name":"Phone","key":"BwcH","pairedAt":0,"push":7}"#
    let recovered = try JSONDecoder().decode(MirrorPairedDevice.self, from: Data(broken.utf8))
    #expect(recovered.push == nil && recovered.name == "Phone")
    let unknownOnly = #"""
      {"id":"00000000-0000-0000-0000-000000000001","name":"Phone","key":"BwcH","pairedAt":0,
       "push":{"token":"\#(Self.token)","kinds":["someday"]}}
      """#
    #expect(try JSONDecoder().decode(MirrorPairedDevice.self, from: Data(unknownOnly.utf8)).push == nil)
    #expect(MirrorPushRegistration(token: Self.token, kinds: []) == nil)
  }

  @Test func registrationAndMacChoiceSurviveASaveAndLoad() throws {
    let device = MirrorPairedDevice(
      id: UUID(), name: "Phone", key: Data(repeating: 1, count: 32), pairedAt: Date(timeIntervalSince1970: 0),
      push: .init(token: Self.token, kinds: [.done]),
      pushAllowedByMac: false)
    let identity = MirrorHostIdentity(id: UUID(), devices: [device])
    let loaded = try JSONDecoder().decode(MirrorHostIdentity.self, from: JSONEncoder().encode(identity))
    #expect(loaded.devices == [device])
  }
}
