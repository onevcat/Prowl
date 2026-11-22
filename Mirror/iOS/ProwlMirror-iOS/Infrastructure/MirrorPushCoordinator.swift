import CryptoKit
import Foundation
import Observation
import os

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
}

/// Every push token of this phone in one Keychain record, so that all of them can be listed:
/// a Host that was forgotten, or a deletion that failed, is never lost.
nonisolated struct MirrorPushTokenState: Codable, Equatable, Sendable {
  var records: [UUID: MirrorPushTokenRecord] = [:]
  /// Tokens to delete at the gateway, kept until the gateway confirms, also across launches.
  var revoking: [String] = []
}

nonisolated struct MirrorPushTokenStorage: Sendable {
  var load: @Sendable () -> MirrorPushTokenState
  var save: @Sendable (MirrorPushTokenState) -> Void

  static let keychain = Self(
    load: { (try? MirrorCredentialVault.load(MirrorPushTokenState.self, account: "push-tokens")) ?? .init() },
    save: { try? MirrorCredentialVault.save($0, account: "push-tokens") })
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
  @ObservationIgnored private let saveShowsDetails: (Bool) throws -> Void
  @ObservationIgnored private var state: MirrorPushTokenState
  /// Bumped when a Host's registration is revoked (switch off, no kinds, forgotten): work
  /// started before must not create or keep a token for it.
  @ObservationIgnored private var revocations: [UUID: Int] = [:]
  /// Bumped when a Host's kinds change: work started before must not send its `pushRegister`.
  @ObservationIgnored private var changes: [UUID: Int] = [:]
  /// Bumped when a pairing is forgotten, also while another pairing of its Host owns the token.
  @ObservationIgnored private var forgottenPairings: [UUID: Int] = [:]
  /// Registrations of one Host run one after another, so the pairing that owns its token, key
  /// and message is always the one that finished last.
  @ObservationIgnored private var hostQueues: [UUID: Task<Void, Never>] = [:]
  /// Bumped by every change of the switch: work started before an off and on must stop too.
  @ObservationIgnored private var switches = 0
  @ObservationIgnored private var draining: Task<Void, Never>?

  init(
    defaults: UserDefaults = .standard,
    gateway: MirrorPushGatewayClient = MirrorPushGatewayClient(),
    tokens: MirrorPushTokenStorage = .keychain,
    registerAPNs: @escaping () async -> String? = { await MirrorPushRegistrar.shared.register() },
    environment: @escaping () -> MirrorAPNsEnvironment = { .current },
    saveKey: @escaping (SymmetricKey, UUID) throws -> Void = { try MirrorPushKeyStore.save($0, hostID: $1) },
    removeKey: @escaping (UUID) throws -> Void = { try MirrorPushKeyStore.remove(hostID: $0) },
    now: @escaping () -> Date = Date.init,
    showsDetails: @escaping () -> Bool = { MirrorPushKeyStore.showsDetails },
    saveShowsDetails: @escaping (Bool) throws -> Void = { try MirrorPushKeyStore.setShowsDetails($0) }
  ) {
    self.defaults = defaults
    self.gateway = gateway
    self.tokens = tokens
    self.registerAPNs = registerAPNs
    self.environment = environment
    self.saveKey = saveKey
    self.now = now
    self.removeKey = removeKey
    self.saveShowsDetails = saveShowsDetails
    self.showsDetails = showsDetails()
    state = tokens.load()
    isEnabled = defaults.bool(forKey: Self.enabledKey)
    let stored = defaults.dictionary(forKey: Self.kindsKey) as? [String: [String]] ?? [:]
    hostKinds = Dictionary(
      uniqueKeysWithValues: stored.compactMap { key, values in
        UUID(uuidString: key).map { ($0, Set(values.compactMap(MirrorPushKind.init(rawValue:)))) }
      })
  }

  /// The global switch. Mirrored in a stored property so that views observe it.
  private(set) var isEnabled: Bool
  /// **Show Details**: the extension shows the tab name and the Host's text instead of the
  /// generic text. Stored in the shared Keychain group, where the extension reads it.
  private(set) var showsDetails: Bool

  func setShowsDetails(_ on: Bool) {
    do {
      try saveShowsDetails(on)
      showsDetails = on
    } catch {
      MirrorLog.push.error("Saving Show Details failed: \(String(describing: error), privacy: .private)")
    }
  }

  /// Event kinds per Host UUID; a Host missing here gets every kind.
  private(set) var hostKinds: [UUID: Set<MirrorPushKind>]

  static let kindsKey = "mirrorPushKinds"

  func kinds(for hostID: UUID) -> Set<MirrorPushKind> { hostKinds[hostID] ?? Set(MirrorPushKind.allCases) }

  /// A change of kinds makes an older registration's message stale; no kinds left revokes the
  /// Host's token at once, also while the Host is offline.
  func setKinds(_ kinds: Set<MirrorPushKind>, for hostID: UUID) {
    hostKinds[hostID] = kinds
    let stored = hostKinds.mapValues { $0.map(\.rawValue).sorted() }
    defaults.set(Dictionary(uniqueKeysWithValues: stored.map { ($0.key.uuidString, $0.value) }), forKey: Self.kindsKey)
    changes[hostID, default: 0] += 1
    if kinds.isEmpty { revoke(hostID) }
  }

  /// Turning on makes the next registration ask for permission and an APNs token. Turning off
  /// revokes every token (also of Hosts that are offline or were forgotten); the caller sends
  /// `pushUnregister` to the connected Hosts.
  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.enabledKey)
    switches += 1
    guard !enabled else { return }
    for hostID in state.records.keys { revoke(hostID) }
  }

  /// A pairing was forgotten on this phone: if it carries the Host's notifications, its token
  /// is revoked and its key removed. Another pairing of the same Host keeps its own.
  func removeRegistration(for hostID: UUID, deviceID: UUID?) async {
    if let deviceID { forgottenPairings[deviceID, default: 0] += 1 }
    if let record = state.records[hostID], deviceID != nil, record.deviceID != deviceID { return }
    revoke(hostID)
    await retryRevocations()
  }

  /// At launch and on each return to the foreground: deletions that failed are tried again
  /// (also while notifications are off), and while they are on, every token follows a new
  /// APNs token, so Hosts that are offline keep reaching the phone.
  func appBecameActive() async {
    await retryRevocations()
    guard isEnabled, !state.records.isEmpty, let apnsToken = await registerAPNs() else { return }
    let environment = environment().rawValue
    for (hostID, record) in state.records where record.apnsToken != apnsToken || record.environment != environment {
      let ticket = ticket(for: hostID, deviceID: record.deviceID)
      guard isCurrent(ticket, forToken: true) else { continue }
      if record.environment != environment {
        // Another build replaced this one; the next connection creates a token for it.
        retire(hostID, record)
        continue
      }
      do {
        try await gateway.updateToken(record.pushToken, apnsToken: apnsToken, allowed: permission(ticket))
        if state.records[hostID]?.pushToken == record.pushToken {
          mutate { $0.records[hostID] = record.moved(to: apnsToken, at: now()) }
        }
      } catch MirrorPushGatewayError.refused(let status) where status == 404 || status == 403 {
        // Gone, or owned by an earlier installation: the next connection gets a new token.
        if state.records[hostID]?.pushToken == record.pushToken { mutate { $0.records[hostID] = nil } }
      } catch {
        MirrorLog.push.error("Moving a push token failed: \(String(describing: error), privacy: .private)")
      }
    }
  }

  /// Deletes the revoked tokens in order; one drain at a time. A failure stops the drain and
  /// keeps the rest for the next attempt. A `403` means an earlier installation owns the
  /// token, which this phone can no longer delete.
  func retryRevocations() async {
    if let draining { return await draining.value }
    let task = Task { await self.drainRevocations() }
    draining = task
    await task.value
    draining = nil
  }

  private func drainRevocations() async {
    while let pushToken = state.revoking.first {
      do {
        try await gateway.deleteToken(pushToken)
      } catch MirrorPushGatewayError.refused(status: 403) {
        MirrorLog.push.error("A push token of an earlier installation cannot be deleted")
      } catch {
        MirrorLog.push.error("Deleting a push token failed: \(String(describing: error), privacy: .private)")
        return
      }
      mutate { $0.revoking.removeAll { $0 == pushToken } }
    }
  }

  /// Moves a token that no longer fits (another pairing or build) to the deletion queue,
  /// without revoking the Host: its next registration creates the replacement.
  private func retire(_ hostID: UUID, _ record: MirrorPushTokenRecord) {
    guard state.records[hostID]?.pushToken == record.pushToken else { return }
    mutate {
      $0.records[hostID] = nil
      $0.revoking.append(record.pushToken)
    }
    Task { await retryRevocations() }
  }

  /// Checked by the gateway client right before a queued create or update leaves.
  private func permission(_ ticket: Ticket) -> MirrorPushGatewayClient.Permission {
    { await MainActor.run { self.isCurrent(ticket, forToken: true) } }
  }

  /// Synchronous, so no registration in flight can see the token again.
  private func revoke(_ hostID: UUID) {
    revocations[hostID, default: 0] += 1
    statuses[hostID] = nil
    try? removeKey(hostID)
    if let record = state.records[hostID] {
      mutate {
        $0.records[hostID] = nil
        $0.revoking.append(record.pushToken)
      }
    }
    Task { await retryRevocations() }
  }

  private struct Ticket: Sendable {
    let hostID: UUID
    let deviceID: UUID
    let switches: Int
    let revocation: Int
    let forgotten: Int
    let change: Int
  }

  private func ticket(for hostID: UUID, deviceID: UUID) -> Ticket {
    Ticket(
      hostID: hostID, deviceID: deviceID, switches: switches, revocation: revocations[hostID, default: 0],
      forgotten: forgottenPairings[deviceID, default: 0], change: changes[hostID, default: 0])
  }

  /// A token may be created or kept while the switch is on and neither the Host nor the pairing
  /// was revoked since; a `pushRegister` may be sent only if the Host's kinds did not change
  /// either.
  private func isCurrent(_ ticket: Ticket, forToken: Bool = false) -> Bool {
    isEnabled && switches == ticket.switches && revocations[ticket.hostID, default: 0] == ticket.revocation
      && forgottenPairings[ticket.deviceID, default: 0] == ticket.forgotten
      && (forToken || changes[ticket.hostID, default: 0] == ticket.change)
  }

  private func mutate(_ change: (inout MirrorPushTokenState) -> Void) {
    change(&state)
    tokens.save(state)
  }

  /// The message for a Host connection that just listed its panes, or `nil` when nothing should
  /// be sent: notifications are off, the Host lacks `push-v1`, a step failed, or the settings
  /// changed while it ran.
  /// `deliverable` says whether the connection that asked can still send the result; a
  /// replacement token is committed only while it can.
  func registration(
    for credential: MirrorDeviceCredential, capabilities: Set<String>, deliverable: @escaping () -> Bool = { true }
  ) async -> MirrorMessage? {
    guard isEnabled, capabilities.contains("push-v1") else { return nil }
    let hostID = credential.hostID
    let kinds = kinds(for: hostID)
    if kinds.isEmpty {
      revoke(hostID)
      return .pushUnregister
    }
    // The ticket is taken now: a change while this waits for the Host's queue makes it stale.
    let ticket = ticket(for: hostID, deviceID: credential.deviceID)
    let previous = hostQueues[hostID]
    let task = Task { () -> MirrorMessage? in
      await previous?.value
      return await self.register(credential, kinds: kinds, ticket: ticket, deliverable: deliverable)
    }
    hostQueues[hostID] = Task { _ = await task.value }
    return await task.value
  }

  /// A new token is only prepared by the gateway. It becomes the Host's owner in one
  /// synchronous step, after the settings are still current, the connection can still send
  /// it, and its key is saved; only then is the token it replaces deleted. Otherwise the new
  /// token is revoked and the previous owner keeps working.
  private func register(
    _ credential: MirrorDeviceCredential, kinds: Set<MirrorPushKind>, ticket: Ticket,
    deliverable: () -> Bool
  ) async -> MirrorMessage? {
    guard isCurrent(ticket), let apnsToken = await registerAPNs(), isCurrent(ticket) else { return nil }
    let prepared: PreparedToken
    do {
      prepared = try await pushToken(for: credential, apnsToken: apnsToken, ticket: ticket)
    } catch {
      MirrorLog.push.error("Push registration for a Host failed: \(String(describing: error), privacy: .private)")
      return nil
    }
    guard isCurrent(ticket), deliverable() else {
      abandon(prepared)
      return nil
    }
    do {
      try saveKey(MirrorPushCrypto.key(deviceSecret: credential.key, hostID: credential.hostID), credential.hostID)
    } catch {
      MirrorLog.push.error("Saving the push key failed: \(String(describing: error), privacy: .private)")
      abandon(prepared)
      return nil
    }
    if case .created(let record) = prepared { commit(record, for: credential.hostID) }
    return .pushRegister(.init(pushToken: prepared.pushToken, kinds: kinds.map(\.rawValue).sorted()))
  }

  private enum PreparedToken {
    /// The Host's own token, already stored.
    case existing(String)
    /// A new token from the gateway, not stored yet.
    case created(MirrorPushTokenRecord)

    var pushToken: String {
      switch self {
      case .existing(let token): token
      case .created(let record): record.pushToken
      }
    }
  }

  private func abandon(_ prepared: PreparedToken) {
    guard case .created(let record) = prepared else { return }
    mutate { $0.revoking.append(record.pushToken) }
    Task { await retryRevocations() }
  }

  private func commit(_ record: MirrorPushTokenRecord, for hostID: UUID) {
    let replaced = state.records[hostID]
    mutate {
      $0.records[hostID] = record
      if let replaced, replaced.pushToken != record.pushToken { $0.revoking.append(replaced.pushToken) }
    }
    if replaced != nil { Task { await retryRevocations() } }
  }

  func received(_ status: MirrorMessage.PushStatusPayload, hostID: UUID) {
    statuses[hostID] = status
  }

  private struct Superseded: Error {}

  /// The stored token while it belongs to this pairing and build, is fresh, and points at this
  /// APNs token. Otherwise the gateway confirms it with `PUT` (which also moves it to a new
  /// APNs token). A token the gateway no longer knows, or that an earlier installation owns,
  /// or a token of another pairing or build, gets a replacement, which `register` commits or
  /// abandons. Nothing reaches the gateway once the Host or pairing was revoked.
  private func pushToken(
    for credential: MirrorDeviceCredential, apnsToken: String, ticket: Ticket
  ) async throws -> PreparedToken {
    let hostID = credential.hostID
    let environment = environment().rawValue
    if let record = state.records[hostID], record.deviceID == credential.deviceID, record.environment == environment {
      if record.apnsToken == apnsToken, now().timeIntervalSince(record.checkedAt) < Self.checkInterval {
        return .existing(record.pushToken)
      }
      do {
        try await gateway.updateToken(record.pushToken, apnsToken: apnsToken, allowed: permission(ticket))
        guard isCurrent(ticket, forToken: true), state.records[hostID]?.pushToken == record.pushToken else {
          throw Superseded()
        }
        mutate { $0.records[hostID] = record.moved(to: apnsToken, at: now()) }
        return .existing(record.pushToken)
      } catch MirrorPushGatewayError.refused(let status) where status == 404 || status == 403 {
        if state.records[hostID]?.pushToken == record.pushToken { mutate { $0.records[hostID] = nil } }
      }
    }
    guard isCurrent(ticket, forToken: true) else { throw Superseded() }
    let pushToken = try await gateway.createToken(
      apnsToken: apnsToken, environment: .init(rawValue: environment) ?? .production, allowed: permission(ticket))
    return .created(
      .init(
        pushToken: pushToken, apnsToken: apnsToken, environment: environment, deviceID: credential.deviceID,
        checkedAt: now()))
  }
}

extension MirrorPushTokenRecord {
  nonisolated func moved(to apnsToken: String, at date: Date) -> Self {
    .init(pushToken: pushToken, apnsToken: apnsToken, environment: environment, deviceID: deviceID, checkedAt: date)
  }
}
