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

  init(
    makeSession: @escaping (MirrorHostRecord) -> MirrorHostSession = { MirrorHostSession(configuration: $0.configuration) },
    makePaneSession: @escaping (MirrorHostRecord) -> MirrorSession = { MirrorSession(configuration: $0.configuration) }
  ) {
    self.makeSession = makeSession
    self.makePaneSession = makePaneSession
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

  func suspendAll() {
    for session in sessions.values { session.stop() }
  }

  func resumeAll() {
    for session in sessions.values where session.status != .ready && session.retriesAutomatically { session.retry() }
  }
}
