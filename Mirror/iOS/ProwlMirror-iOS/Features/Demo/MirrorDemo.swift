import Foundation
import SwiftUI

/// The demo (docs-ai 098): the app's own store and sessions, pointed at `MirrorDemoHost`
/// instead of the network. It keeps nothing: its store lives in a suite that is cleared when
/// the demo starts and ends, and no credential, push token or socket is made.
@MainActor
final class MirrorDemo {
  static let defaultsSuite = "com.onevcat.prowl.mirror.demo"

  let host: MirrorDemoHost
  let store: MirrorHostStore
  let sessions: MirrorHostSessions
  private let defaults: UserDefaults

  init(host: MirrorDemoHost = MirrorDemoHost()) {
    self.host = host
    defaults = UserDefaults(suiteName: Self.defaultsSuite) ?? UserDefaults()
    defaults.removePersistentDomain(forName: Self.defaultsSuite)
    store = MirrorHostStore(defaults: defaults, adoptsLegacyConnection: false)
    let record = store.upsert(address: "demo.invalid", port: 7880, hostID: nil)
    store.updateHostName(record.id, name: host.hostName)
    sessions = MirrorHostSessions(
      makeSession: { MirrorHostSession(configuration: $0.configuration, makeTransport: { _ in host.makeTransport() }) },
      makePaneSession: { MirrorSession(configuration: $0.configuration, makeTransport: { _ in host.makeTransport() }) },
      deviceID: { _ in nil })
    host.start()
  }

  func end() {
    sessions.suspendAll()
    host.stop()
    defaults.removePersistentDomain(forName: Self.defaultsSuite)
  }
}

/// What the Agents title menu offers in the demo, in place of the Host list actions.
struct MirrorDemoActions {
  /// Leaves the demo and opens pairing.
  let pair: () -> Void
  let exit: () -> Void
}

extension EnvironmentValues {
  /// Set only while the demo runs.
  @Entry var mirrorDemo: MirrorDemoActions?
}
