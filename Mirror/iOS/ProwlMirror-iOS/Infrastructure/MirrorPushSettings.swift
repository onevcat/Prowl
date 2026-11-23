import Foundation
import Observation
import os

/// What the user chose for notifications on this phone (docs-ai 095 P3e). Only stores the
/// choices; `MirrorPushCoordinator` changes the switch and the kinds, because those also revoke
/// tokens.
@Observable
final class MirrorPushSettings {
  static let enabledKey = "mirrorPushEnabled"
  static let kindsKey = "mirrorPushKinds"

  /// The switch for this phone.
  private(set) var isEnabled: Bool
  /// **Show Details**: the extension shows the tab name and the Host's text instead of the
  /// generic text. Stored in the shared Keychain group, where the extension reads it.
  private(set) var showsDetails: Bool
  /// Event kinds per Host UUID; a Host missing here gets every kind.
  private(set) var hostKinds: [UUID: Set<MirrorPushKind>]

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let saveShowsDetails: (Bool) throws -> Void

  init(
    defaults: UserDefaults = .standard,
    showsDetails: () -> Bool = { MirrorPushKeyStore.showsDetails },
    saveShowsDetails: @escaping (Bool) throws -> Void = { try MirrorPushKeyStore.setShowsDetails($0) }
  ) {
    self.defaults = defaults
    self.saveShowsDetails = saveShowsDetails
    self.showsDetails = showsDetails()
    isEnabled = defaults.bool(forKey: Self.enabledKey)
    let stored = defaults.dictionary(forKey: Self.kindsKey) as? [String: [String]] ?? [:]
    hostKinds = Dictionary(
      uniqueKeysWithValues: stored.compactMap { key, values in
        UUID(uuidString: key).map { ($0, Set(values.compactMap(MirrorPushKind.init(rawValue:)))) }
      })
  }

  func kinds(for hostID: UUID) -> Set<MirrorPushKind> { hostKinds[hostID] ?? Set(MirrorPushKind.allCases) }

  func setShowsDetails(_ on: Bool) {
    do {
      try saveShowsDetails(on)
      showsDetails = on
    } catch {
      MirrorLog.push.error("Saving Show Details failed: \(String(describing: error), privacy: .private)")
    }
  }

  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.enabledKey)
  }

  func setKinds(_ kinds: Set<MirrorPushKind>, for hostID: UUID) {
    hostKinds[hostID] = kinds
    let stored = hostKinds.map { ($0.key.uuidString, $0.value.map(\.rawValue).sorted()) }
    defaults.set(Dictionary(uniqueKeysWithValues: stored), forKey: Self.kindsKey)
  }
}
