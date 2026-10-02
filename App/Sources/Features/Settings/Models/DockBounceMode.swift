import Foundation

/// Controls whether and how the Prowl dock icon bounces when an in-app
/// notification is received.
///
/// Persistence: encoded as the raw `String` (case name). Cases must never
/// be renamed once shipped because user JSON references them by name.
enum DockBounceMode: String, CaseIterable, Identifiable, Codable, Sendable {
  /// Do not bounce the dock icon.
  case off
  /// Bounce the dock icon once (`NSRequestUserAttentionType.informationalRequest`).
  case once
  /// Bounce the dock icon repeatedly until Prowl is brought to the front
  /// (`NSRequestUserAttentionType.criticalRequest`).
  case continuous

  var id: String { rawValue }

  var title: String {
    switch self {
    case .off:
      return String(localized: "Off")
    case .once:
      return String(localized: "Once")
    case .continuous:
      return String(localized: "Continuously")
    }
  }
}
