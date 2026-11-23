import Foundation

/// Opens what a tapped notification points at (docs-ai 095 P3f): shows its Host, connects if
/// needed, and opens the pane once the Host lists it. A pane that is gone, or a Host that cannot
/// be reached, leaves the agents list. A newer tap, or a Host switch by the user, takes over:
/// this one then changes nothing.
struct MirrorNotificationOpener {
  enum Outcome: Equatable {
    /// Another tap or the user took over, or no paired Host matches.
    case unchanged
    case agents
    case pane(MirrorPaneRoute)
  }

  let router: MirrorNotificationRouter
  let store: MirrorHostStore
  let sessions: MirrorHostSessions

  /// `show` is called with the Host to open before it is selected and connected; the caller
  /// closes what covers it and selects it.
  func open(_ target: MirrorNotificationRouter.Target, show: (MirrorHostRecord) -> Void) async -> Outcome {
    guard
      let host = MirrorNotificationRouter.entry(
        for: target.hostID, among: store.hosts, selectedID: store.selectedHost?.id,
        isConnected: { sessions.existing(for: $0)?.status == .ready })
    else {
      router.finish(target)
      return .unchanged
    }
    show(host)
    let session = sessions.session(for: host)
    if case .failed = session.status { session.retry() } else { session.start() }
    await session.settled()
    guard router.owns(target, selectedHostID: store.selectedHost?.id, hostRecordID: host.id) else {
      router.finish(target)
      return .unchanged
    }
    router.finish(target)
    guard session.status == .ready,
      let route = MirrorNotificationRouter.route(for: target, host: host, panes: session.panes)
    else { return .agents }
    return .pane(route)
  }
}
