import CryptoKit
import Foundation
import Observation
import os

/// Push registration with each Host (docs-ai 095 P3d, P3e). While notifications are on, every
/// connection to a Host with `push-v1` sends `pushRegister` with that Host's event kinds; the
/// push key and the push token are prepared first. Nothing is sent to the gateway while
/// notifications are off, except deleting the tokens when they are turned off.
@Observable
final class MirrorPushCoordinator {
  static let shared = MirrorPushCoordinator()

  /// The Host's last answer, by Host UUID.
  private(set) var statuses: [UUID: MirrorMessage.PushStatusPayload] = [:]
  /// The user's choices. Change the switch and the kinds here, not on `settings`: they also
  /// revoke tokens.
  let settings: MirrorPushSettings

  @ObservationIgnored private let gateway: MirrorPushGatewayClient
  @ObservationIgnored private let tokens: MirrorPushTokenStorage
  @ObservationIgnored private let registerAPNs: () async -> String?
  @ObservationIgnored private let environment: () -> MirrorAPNsEnvironment
  @ObservationIgnored private let saveKey: (SymmetricKey, UUID) throws -> Void
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private let removeKey: (UUID) throws -> Void
  @ObservationIgnored private var ledger: MirrorPushTokenLedger
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
    settings: MirrorPushSettings = MirrorPushSettings(),
    gateway: MirrorPushGatewayClient = MirrorPushGatewayClient(),
    tokens: MirrorPushTokenStorage = .keychain,
    registerAPNs: @escaping () async -> String? = { await MirrorPushRegistrar.shared.register() },
    environment: @escaping () -> MirrorAPNsEnvironment = { .current },
    saveKey: @escaping (SymmetricKey, UUID) throws -> Void = { try MirrorPushKeyStore.save($0, hostID: $1) },
    removeKey: @escaping (UUID) throws -> Void = { try MirrorPushKeyStore.remove(hostID: $0) },
    now: @escaping () -> Date = Date.init
  ) {
    self.settings = settings
    self.gateway = gateway
    self.tokens = tokens
    self.registerAPNs = registerAPNs
    self.environment = environment
    self.saveKey = saveKey
    self.now = now
    self.removeKey = removeKey
    ledger = tokens.load()
  }

  /// A change of kinds makes an older registration's message stale; no kinds left revokes the
  /// Host's token at once, also while the Host is offline.
  func setKinds(_ kinds: Set<MirrorPushKind>, for hostID: UUID) {
    settings.setKinds(kinds, for: hostID)
    changes[hostID, default: 0] += 1
    if kinds.isEmpty { revoke(hostID) }
  }

  /// Turning on makes the next registration ask for permission and an APNs token. Turning off
  /// revokes every token (also of Hosts that are offline or were forgotten); the caller sends
  /// `pushUnregister` to the connected Hosts.
  func setEnabled(_ enabled: Bool) {
    settings.setEnabled(enabled)
    switches += 1
    guard !enabled else { return }
    for hostID in ledger.records.keys { revoke(hostID) }
  }

  /// A pairing was forgotten on this phone: if it carries the Host's notifications, its token
  /// is revoked and its key removed. Another pairing of the same Host keeps its own.
  func removeRegistration(for hostID: UUID, deviceID: UUID?) async {
    if let deviceID { forgottenPairings[deviceID, default: 0] += 1 }
    if let record = ledger.records[hostID], deviceID != nil, record.deviceID != deviceID { return }
    revoke(hostID)
    await retryRevocations()
  }

  /// At launch and on each return to the foreground: deletions that failed are tried again
  /// (also while notifications are off), and while they are on, every token follows a new
  /// APNs token, so Hosts that are offline keep reaching the phone.
  func appBecameActive() async {
    await retryRevocations()
    guard settings.isEnabled, !ledger.records.isEmpty, let apnsToken = await registerAPNs() else { return }
    let environment = environment().rawValue
    for (hostID, record) in ledger.outdated(apnsToken: apnsToken, environment: environment) {
      let ticket = ticket(for: hostID, deviceID: record.deviceID)
      guard isCurrent(ticket, forToken: true) else { continue }
      if record.environment != environment {
        // Another build replaced this one; the next connection creates a token for it.
        retire(hostID, record)
        continue
      }
      do {
        try await gateway.updateToken(record.pushToken, apnsToken: apnsToken, allowed: permission(ticket))
        mutate { $0.confirm(hostID, record.pushToken, apnsToken: apnsToken, at: now()) }
      } catch MirrorPushGatewayError.refused(let status) where status == 404 || status == 403 {
        // Gone, or owned by an earlier installation: the next connection gets a new token.
        mutate { $0.drop(hostID, record.pushToken) }
      } catch {
        Self.logFailure("Moving a push token", error)
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
    while let pushToken = ledger.revoking.first {
      do {
        try await gateway.deleteToken(pushToken)
      } catch MirrorPushGatewayError.refused(status: 403) {
        MirrorLog.push.error("A push token of an earlier installation cannot be deleted")
      } catch {
        Self.logFailure("Deleting a push token", error)
        return
      }
      mutate { $0.deleted(pushToken) }
    }
  }

  /// Moves a token that no longer fits (another pairing or build) to the deletion queue,
  /// without revoking the Host: its next registration creates the replacement.
  private func retire(_ hostID: UUID, _ record: MirrorPushTokenRecord) {
    if mutate({ $0.retire(hostID, record.pushToken) }) { Task { await retryRevocations() } }
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
    mutate { $0.revoke(hostID) }
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
    settings.isEnabled && switches == ticket.switches && revocations[ticket.hostID, default: 0] == ticket.revocation
      && forgottenPairings[ticket.deviceID, default: 0] == ticket.forgotten
      && (forToken || changes[ticket.hostID, default: 0] == ticket.change)
  }

  @discardableResult
  private func mutate<Result>(_ change: (inout MirrorPushTokenLedger) -> Result) -> Result {
    let before = ledger
    let result = change(&ledger)
    if ledger != before { tokens.save(ledger) }
    return result
  }

  /// The message for a Host connection that just listed its panes, or `nil` when nothing should
  /// be sent: notifications are off, the Host lacks `push-v1`, a step failed, or the settings
  /// changed while it ran.
  /// `deliverable` says whether the connection that asked can still send the result; a
  /// replacement token is committed only while it can.
  func registration(
    for credential: MirrorDeviceCredential, capabilities: Set<String>, deliverable: @escaping () -> Bool = { true }
  ) async -> MirrorMessage? {
    guard settings.isEnabled, capabilities.contains(MirrorPushContract.capability) else { return nil }
    let hostID = credential.hostID
    let kinds = settings.kinds(for: hostID)
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
    guard isCurrent(ticket) else { return nil }
    guard let apnsToken = await registerAPNs() else {
      MirrorLog.push.info("Push registration stopped: no APNs token (permission off, or APNs unavailable)")
      return nil
    }
    guard isCurrent(ticket) else { return nil }
    let prepared: PreparedToken
    do {
      prepared = try await pushToken(for: credential, apnsToken: apnsToken, ticket: ticket)
    } catch {
      if error is Superseded {
        MirrorLog.push.info("Push registration dropped: the settings changed meanwhile")
      } else {
        Self.logFailure("Push registration for a Host", error)
      }
      return nil
    }
    guard isCurrent(ticket), deliverable() else {
      MirrorLog.push.info("Push registration dropped: the settings changed or the connection closed meanwhile")
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
    mutate { $0.abandon(record.pushToken) }
    Task { await retryRevocations() }
  }

  private func commit(_ record: MirrorPushTokenRecord, for hostID: UUID) {
    if mutate({ $0.commit(record, for: hostID) }) { Task { await retryRevocations() } }
  }

  func received(_ status: MirrorMessage.PushStatusPayload, hostID: UUID) {
    statuses[hostID] = status
  }

  /// The Host says that the gateway no longer knows this token. It is forgotten without a
  /// deletion; the next registration creates a new one.
  func tokenGone(_ pushToken: String, hostID: UUID) {
    MirrorLog.push.info("The Host says the gateway no longer knows a push token; registering a new one")
    mutate { $0.drop(hostID, pushToken) }
  }

  /// Gateway errors hold only status codes, so they are logged in full; other errors may hold
  /// addresses and stay private.
  private static func logFailure(_ step: String, _ error: any Error) {
    if let gateway = error as? MirrorPushGatewayError {
      MirrorLog.push.error("\(step, privacy: .public) failed: \(String(describing: gateway), privacy: .public)")
    } else {
      MirrorLog.push.error("\(step, privacy: .public) failed: \(String(describing: error), privacy: .private)")
    }
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
    if let record = ledger.record(for: hostID, deviceID: credential.deviceID, environment: environment) {
      if record.isFresh(apnsToken: apnsToken, at: now()) { return .existing(record.pushToken) }
      do {
        try await gateway.updateToken(record.pushToken, apnsToken: apnsToken, allowed: permission(ticket))
        guard isCurrent(ticket, forToken: true), ledger.owns(hostID, record.pushToken) else { throw Superseded() }
        mutate { $0.confirm(hostID, record.pushToken, apnsToken: apnsToken, at: now()) }
        return .existing(record.pushToken)
      } catch MirrorPushGatewayError.refused(let status) where status == 404 || status == 403 {
        mutate { $0.drop(hostID, record.pushToken) }
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
