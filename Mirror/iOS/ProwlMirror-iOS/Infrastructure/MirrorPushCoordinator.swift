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

/// Push registration with each Host (docs-ai 095 P3d). While notifications are on, every
/// connection to a Host with `push-v1` sends `pushRegister`; the push key and the push token
/// are prepared first. Nothing is sent or stored while notifications are off.
@Observable
final class MirrorPushCoordinator {
  static let shared = MirrorPushCoordinator()
  static let enabledKey = "mirrorPushEnabled"
  static let kinds = MirrorPushKind.allCases.map(\.rawValue)
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

  init(
    defaults: UserDefaults = .standard,
    gateway: MirrorPushGatewayClient = MirrorPushGatewayClient(),
    tokens: MirrorPushTokenStorage = .keychain,
    registerAPNs: @escaping () async -> String? = { await MirrorPushRegistrar.shared.register() },
    environment: @escaping () -> MirrorAPNsEnvironment = { .current },
    saveKey: @escaping (SymmetricKey, UUID) throws -> Void = { try MirrorPushKeyStore.save($0, hostID: $1) },
    now: @escaping () -> Date = Date.init
  ) {
    self.defaults = defaults
    self.gateway = gateway
    self.tokens = tokens
    self.registerAPNs = registerAPNs
    self.environment = environment
    self.saveKey = saveKey
    self.now = now
  }

  var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

  /// The message for a Host connection that just listed its panes, or `nil` when nothing should
  /// be sent: notifications are off, the Host lacks `push-v1`, or a step failed.
  func registration(for credential: MirrorDeviceCredential, capabilities: Set<String>) async -> MirrorMessage? {
    guard isEnabled, capabilities.contains("push-v1") else { return nil }
    let hostID = credential.hostID
    do {
      try saveKey(MirrorPushCrypto.key(deviceSecret: credential.key, hostID: hostID), hostID)
    } catch {
      MirrorLog.push.error("Saving the push key failed: \(String(describing: error), privacy: .private)")
      return nil
    }
    guard let apnsToken = await registerAPNs() else { return nil }
    do {
      let pushToken = try await pushToken(for: hostID, apnsToken: apnsToken)
      return .pushRegister(.init(pushToken: pushToken, kinds: Self.kinds))
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
