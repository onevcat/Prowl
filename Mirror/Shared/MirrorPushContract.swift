import Foundation

/// The parts of the Mirror push contract that the Host and the phone compile from one source
/// (docs-ai 095). What a test must check across codebases, including the gateway, is in
/// `Mirror/Fixtures/push/contract.json`.
nonisolated enum MirrorPushContract {
  static let capability = "push-v1"

  /// The gateway for every build. Each push token keeps the APNs environment that the phone
  /// reported, and works only at the gateway that issued it, so the Host and the phone must
  /// use this same address.
  static let gatewayURL = URL(string: "https://prowl-push.onev.dev")!
}

/// `pushRegister`: where the Host sends push events for this device, and which events. The
/// phone sends it on every connection.
nonisolated struct MirrorPushRegisterPayload: Codable, Equatable, Sendable {
  /// The send-only token that the push gateway issued for this device and Host.
  var pushToken: String
  /// `MirrorPushKind` raw values; the Host ignores a kind that it does not know.
  var kinds: [String]
}

/// `pushStatus`: the Host's reply to `pushRegister` and `pushUnregister`.
nonisolated struct MirrorPushStatusPayload: Codable, Equatable, Sendable {
  /// The Mac switch **Send Notifications to Paired Devices**.
  var pushEnabled: Bool
  /// `false` when the Mac user turned notifications off for this device.
  var pushAllowedByMac: Bool
  /// Whether the Host keeps a registration for this device now.
  var registered: Bool
}
