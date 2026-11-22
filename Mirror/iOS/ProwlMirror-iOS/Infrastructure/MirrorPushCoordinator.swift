import CryptoKit
import Foundation
import Observation
import os

/// The push token of one Host, and the APNs token it points at.
nonisolated struct MirrorPushTokenRecord: Codable, Equatable, Sendable {
  let pushToken: String
  let apnsToken: String
  /// When the gateway last confirmed the token.
  let checkedAt: Date
}

nonisolated struct MirrorPushTokenStorage: Sendable {
  var load: @Sendable (UUID) -> MirrorPushTokenRecord?
  var save: @Sendable (MirrorPushTokenRecord?, UUID) -> Void

  static let keychain = Self(
    load: { try? MirrorCredentialVault.load(MirrorPushTokenRecord.self, account: "push-token:\($0.uuidString)") },
    save: { record, hostID in
      let account = "push-token:\(hostID.uuidString)"
      if let record {
        try? MirrorCredentialVault.save(record, account: account)
      } else {
        try? MirrorCredentialVault.remove(account: account)
      }
    })
}

/// Push registration with each Host (docs-ai 095 P3d, P3e). While notifications are on, every
/// connection to a Host with `push-v1` sends `pushRegister` with that Host's event kinds; the
/// push key and the push token are prepared first. Nothing is sent to the gateway while
/// notifications are off, except deleting the tokens when they are turned off.
@Observable
final class MirrorPushCoordinator {
  static let shared = MirrorPushCoordinator()
  static let enabledKey = "mirrorPushEnabled"
  /// The gateway deletes tokens unused for 90 days, and a Host keeps sending to a token it was
  /// given; a daily check renews the token or replaces a deleted one.
  static let checkInterval: TimeInterval = 24 * 60 * 60

  /// The Host's last answer, by Host UUID.
  private(set) var statuses: [UUID: MirrorMessage.PushStatusPayload] = [:]

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let gateway: MirrorPushGatewayClient
  @ObservationIgnored private let tokens: MirrorPushTokenStorage
  @ObservationIgnored private let registerAPNs: () async -> String?
  @ObservationIgnored private let environment: () -> MirrorAPNsEnvironment
  @ObservationIgnored private let saveKey: (SymmetricKey, UUID) throws -> Void
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private let removeKey: (UUID) throws -> Void

  init(
    defaults: UserDefaults = .standard,
    gateway: MirrorPushGatewayClient = MirrorPushGatewayClient(),
    tokens: MirrorPushTokenStorage = .keychain,
    registerAPNs: @escaping () async -> String? = { await MirrorPushRegistrar.shared.register() },
    environment: @escaping () -> MirrorAPNsEnvironment = { .current },
    saveKey: @escaping (SymmetricKey, UUID) throws -> Void = { try MirrorPushKeyStore.save($0, hostID: $1) },
    removeKey: @escaping (UUID) throws -> Void = { try MirrorPushKeyStore.remove(hostID: $0) },
    now: @escaping () -> Date = Date.init
  ) {
    self.defaults = defaults
    self.gateway = gateway
    self.tokens = tokens
    self.registerAPNs = registerAPNs
    self.environment = environment
    self.saveKey = saveKey
    self.now = now
    self.removeKey = removeKey
    isEnabled = defaults.bool(forKey: Self.enabledKey)
    let stored = defaults.dictionary(forKey: Self.kindsKey) as? [String: [String]] ?? [:]
    hostKinds = Dictionary(
      uniqueKeysWithValues: stored.compactMap { key, values in
        UUID(uuidString: key).map { ($0, Set(values.compactMap(MirrorPushKind.init(rawValue:)))) }
      })
  }

  /// The global switch. Mirrored in a stored property so that views observe it.
  private(set) var isEnabled: Bool
  /// Event kinds per Host UUID; a Host missing here gets every kind.
  private(set) var hostKinds: [UUID: Set<MirrorPushKind>]

  static let kindsKey = "mirrorPushKinds"

  func kinds(for hostID: UUID) -> Set<MirrorPushKind> { hostKinds[hostID] ?? Set(MirrorPushKind.allCases) }

  func setKinds(_ kinds: Set<MirrorPushKind>, for hostID: UUID) {
    hostKinds[hostID] = kinds
    let stored = hostKinds.mapValues { $0.map(\.rawValue).sorted() }
    defaults.set(Dictionary(uniqueKeysWithValues: stored.map { ($0.key.uuidString, $0.value) }), forKey: Self.kindsKey)
  }

  /// Turning on makes the next registration ask for permission and an APNs token. After
  /// turning off, the caller tells the connected Hosts (`pushUnregister`) and calls
  /// `removeRegistration` for every Host, so Hosts that are offline now stop too.
  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.enabledKey)
  }

  /// The Host was forgotten on this phone, or every kind was turned off for it: its push
  /// token is deleted at the gateway and its key removed. A gateway that cannot be reached
  /// keeps the local record, so a later call can try again.
  func removeRegistration(for hostID: UUID) async {
    statuses[hostID] = nil
    try? removeKey(hostID)
    guard let record = tokens.load(hostID) else { return }
    do {
      try await gateway.deleteToken(record.pushToken)
      tokens.save(nil, hostID)
    } catch {
      MirrorLog.push.error("Deleting a push token failed: \(String(describing: error), privacy: .private)")
    }
  }

  /// The message for a Host connection that just listed its panes, or `nil` when nothing should
  /// be sent: notifications are off, the Host lacks `push-v1`, or a step failed.
  func registration(for credential: MirrorDeviceCredential, capabilities: Set<String>) async -> MirrorMessage? {
    guard isEnabled, capabilities.contains("push-v1") else { return nil }
    let hostID = credential.hostID
    let kinds = kinds(for: hostID)
    if kinds.isEmpty {
      await removeRegistration(for: hostID)
      return .pushUnregister
    }
    do {
      try saveKey(MirrorPushCrypto.key(deviceSecret: credential.key, hostID: hostID), hostID)
    } catch {
      MirrorLog.push.error("Saving the push key failed: \(String(describing: error), privacy: .private)")
      return nil
    }
    guard let apnsToken = await registerAPNs() else { return nil }
    do {
      let pushToken = try await pushToken(for: hostID, apnsToken: apnsToken)
      return .pushRegister(.init(pushToken: pushToken, kinds: kinds.map(\.rawValue).sorted()))
    } catch {
      MirrorLog.push.error("Push token for a Host failed: \(String(describing: error), privacy: .private)")
      return nil
    }
  }

  func received(_ status: MirrorMessage.PushStatusPayload, hostID: UUID) {
    statuses[hostID] = status
  }

  /// The stored token while it is fresh and points at this APNs token. Otherwise the gateway
  /// confirms it with `PUT` (which also moves it to a new APNs token); a token the gateway no
  /// longer knows is replaced.
  private func pushToken(for hostID: UUID, apnsToken: String) async throws -> String {
    if let record = tokens.load(hostID) {
      if record.apnsToken == apnsToken, now().timeIntervalSince(record.checkedAt) < Self.checkInterval {
        return record.pushToken
      }
      do {
        try await gateway.updateToken(record.pushToken, apnsToken: apnsToken)
        tokens.save(.init(pushToken: record.pushToken, apnsToken: apnsToken, checkedAt: now()), hostID)
        return record.pushToken
      } catch MirrorPushGatewayError.refused(status: 404) {
        tokens.save(nil, hostID)
      }
    }
    let pushToken = try await gateway.createToken(apnsToken: apnsToken, environment: environment())
    tokens.save(.init(pushToken: pushToken, apnsToken: apnsToken, checkedAt: now()), hostID)
    return pushToken
  }
}
