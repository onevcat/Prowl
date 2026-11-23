import Foundation

/// The push token of one Host, and the device it points at. One pairing per Host carries
/// notifications: a Mac paired at two addresses has two device credentials, each with its own
/// key, and only the pairing that registered last has a token.
nonisolated struct MirrorPushTokenRecord: Codable, Equatable, Sendable {
  let pushToken: String
  let apnsToken: String
  /// The gateway keeps the environment of a token; a token never moves to another one.
  let environment: String
  /// The pairing (device credential) that registered this token with the Host.
  let deviceID: UUID
  /// When the gateway last confirmed the token.
  let checkedAt: Date

  /// The gateway deletes tokens unused for 90 days, and a Host keeps sending to a token it was
  /// given; a daily check renews the token or replaces a deleted one.
  static let checkInterval: TimeInterval = 24 * 60 * 60

  /// Usable without asking the gateway: it points at this APNs token and was confirmed less
  /// than `checkInterval` ago.
  func isFresh(apnsToken: String, at now: Date) -> Bool {
    self.apnsToken == apnsToken && now.timeIntervalSince(checkedAt) < Self.checkInterval
  }

  func moved(to apnsToken: String, at date: Date) -> Self {
    .init(pushToken: pushToken, apnsToken: apnsToken, environment: environment, deviceID: deviceID, checkedAt: date)
  }
}

/// Every push token of this phone (docs-ai 095), saved as one Keychain record so that all of
/// them can be listed: a Host that was forgotten, or a deletion that failed, is never lost.
///
/// The ledger only keeps the books. Whether a change is still wanted (the switch, the Host's
/// settings, the pairing) is for `MirrorPushCoordinator` to decide; each change here is checked
/// against the token it expects, so a change based on a token that was replaced meanwhile does
/// nothing.
nonisolated struct MirrorPushTokenLedger: Codable, Equatable, Sendable {
  private(set) var records: [UUID: MirrorPushTokenRecord] = [:]
  /// Tokens to delete at the gateway, kept until the gateway confirms, also across launches.
  private(set) var revoking: [String] = []

  init(records: [UUID: MirrorPushTokenRecord] = [:], revoking: [String] = []) {
    self.records = records
    self.revoking = revoking
  }

  /// The Host's token while it belongs to this pairing and this build.
  func record(for hostID: UUID, deviceID: UUID, environment: String) -> MirrorPushTokenRecord? {
    guard let record = records[hostID], record.deviceID == deviceID, record.environment == environment else {
      return nil
    }
    return record
  }

  func owns(_ hostID: UUID, _ pushToken: String) -> Bool { records[hostID]?.pushToken == pushToken }

  /// Tokens that no longer point at this APNs token or this build.
  func outdated(apnsToken: String, environment: String) -> [(hostID: UUID, record: MirrorPushTokenRecord)] {
    records
      .filter { $0.value.apnsToken != apnsToken || $0.value.environment != environment }
      .map { (hostID: $0.key, record: $0.value) }
  }

  /// The Host stops getting notifications: its token goes to the deletion queue. Returns
  /// whether a token was queued.
  @discardableResult
  mutating func revoke(_ hostID: UUID) -> Bool {
    guard let record = records.removeValue(forKey: hostID) else { return false }
    revoking.append(record.pushToken)
    return true
  }

  /// Moves a token that no longer fits (another pairing or build) to the deletion queue,
  /// without revoking the Host: its next registration creates the replacement.
  @discardableResult
  mutating func retire(_ hostID: UUID, _ pushToken: String) -> Bool {
    guard owns(hostID, pushToken) else { return false }
    return revoke(hostID)
  }

  /// The gateway no longer accepts the token (`404`, or `403` for an earlier installation's
  /// token): it is forgotten without a deletion, which would fail the same way.
  mutating func drop(_ hostID: UUID, _ pushToken: String) {
    guard owns(hostID, pushToken) else { return }
    records[hostID] = nil
  }

  /// The gateway confirmed the token, and now sends to `apnsToken`.
  mutating func confirm(_ hostID: UUID, _ pushToken: String, apnsToken: String, at date: Date) {
    guard let record = records[hostID], record.pushToken == pushToken else { return }
    records[hostID] = record.moved(to: apnsToken, at: date)
  }

  /// A new token becomes the Host's owner; the token it replaces goes to the deletion queue.
  /// Returns whether a token was queued.
  @discardableResult
  mutating func commit(_ record: MirrorPushTokenRecord, for hostID: UUID) -> Bool {
    let replaced = records.updateValue(record, forKey: hostID)
    guard let replaced, replaced.pushToken != record.pushToken else { return false }
    revoking.append(replaced.pushToken)
    return true
  }

  /// A token that was created but never became an owner.
  mutating func abandon(_ pushToken: String) {
    revoking.append(pushToken)
  }

  /// The gateway deleted the token, or will never let this phone delete it.
  mutating func deleted(_ pushToken: String) {
    revoking.removeAll { $0 == pushToken }
  }
}

nonisolated struct MirrorPushTokenStorage: Sendable {
  var load: @Sendable () -> MirrorPushTokenLedger
  var save: @Sendable (MirrorPushTokenLedger) -> Void

  static let keychain = Self(
    load: { (try? MirrorCredentialVault.load(MirrorPushTokenLedger.self, account: "push-tokens")) ?? .init() },
    save: { try? MirrorCredentialVault.save($0, account: "push-tokens") })
}
