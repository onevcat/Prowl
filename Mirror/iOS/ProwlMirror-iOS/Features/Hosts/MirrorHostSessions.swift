import Foundation
import Observation

/// One roster connection per Host, kept while the app is active so pane lists and pane
/// support stay fresh behind the pane screen too.
@MainActor
@Observable
final class MirrorHostSessions {
  private var sessions: [UUID: MirrorHostSession] = [:]
  private let makeSession: (MirrorHostRecord) -> MirrorHostSession
  /// The pane connection a pane screen opens; fixtures substitute a fake transport here.
  let makePaneSession: (MirrorHostRecord) -> MirrorSession
  let push: MirrorPushCoordinator
  /// The pairing (device credential) of a paired entry, from the Keychain.
  private let deviceID: (MirrorHostRecord) -> UUID?

  init(
    makeSession: @escaping (MirrorHostRecord) -> MirrorHostSession = { MirrorHostSession(configuration: $0.configuration) },
    makePaneSession: @escaping (MirrorHostRecord) -> MirrorSession = { MirrorSession(configuration: $0.configuration) },
    push: MirrorPushCoordinator = .shared,
    deviceID: @escaping (MirrorHostRecord) -> UUID? = {
      (try? MirrorSavedConnection.load(account: $0.credentialAccount))?.credential?.deviceID
    }
  ) {
    self.makeSession = makeSession
    self.makePaneSession = makePaneSession
    self.push = push
    self.deviceID = deviceID
  }

  func session(for host: MirrorHostRecord) -> MirrorHostSession {
    if let session = sessions[host.id] { return session }
    let session = makeSession(host)
    sessions[host.id] = session
    return session
  }

  func existing(for host: MirrorHostRecord) -> MirrorHostSession? { sessions[host.id] }

  func forget(_ id: UUID) {
    sessions.removeValue(forKey: id)?.stop()
  }

  /// A paired entry is removed from this phone. Its push token is deleted at the gateway, which
  /// stops notifications also while the Host is offline; another address of the same Mac keeps
  /// its own. Call it before the store removes the entry, which deletes its credential.
  func forgetPairing(_ host: MirrorHostRecord) {
    if let hostID = host.hostID {
      let deviceID = deviceID(host)
      Task { [push] in await push.removeRegistration(for: hostID, deviceID: deviceID) }
    }
    forget(host.id)
  }

  /// The notification switch (docs-ai 095). It flips first, so that each connected Host then
  /// hears `pushRegister` or `pushUnregister`; turning off also revokes every token.
  func setNotificationsEnabled(_ enabled: Bool) {
    push.setEnabled(enabled)
    for session in sessions.values { session.pushSettingsChanged() }
  }

  /// One Mac's event kinds reach every connected address of that Mac, whichever pairing carries
  /// its notifications. No kinds left revokes the token at once, also while the Mac is offline.
  func setNotificationKinds(_ kinds: Set<MirrorPushKind>, for hostID: UUID) {
    push.setKinds(kinds, for: hostID)
    for session in sessions(of: hostID) { session.pushSettingsChanged() }
  }

  /// Whether the Mac can send notifications, from any connected address; `nil` while none is
  /// connected.
  func supportsPush(hostID: UUID) -> Bool? {
    let answers = sessions(of: hostID).compactMap(\.supportsPush)
    return answers.isEmpty ? nil : answers.contains(true)
  }

  private func sessions(of hostID: UUID) -> [MirrorHostSession] {
    sessions.values.filter { $0.configuration.credential?.hostID == hostID }
  }

  func suspendAll() {
    for session in sessions.values { session.stop() }
  }

  func resumeAll() {
    for session in sessions.values where session.status != .ready && session.retriesAutomatically { session.retry() }
  }
}
