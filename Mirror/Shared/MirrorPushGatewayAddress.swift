import Foundation

/// The push gateway for every build (docs-ai 095). Each push token keeps the APNs
/// environment that the phone reported, and works only at the gateway that issued it, so the
/// Host and the phone must use this same address.
nonisolated enum MirrorPushGatewayAddress {
  static let url = URL(string: "https://prowl-push.onev.dev")!
}
