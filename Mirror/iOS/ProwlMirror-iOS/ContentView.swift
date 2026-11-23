import SwiftUI

/// Agents of the chosen Host → one pane (docs-ai 089). DEBUG fixture arguments replace the network with
/// fake Hosts so UI tests and screenshots need none.
struct ContentView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var hosts = MirrorHostStore()
  @State private var sessions = MirrorHostSessions()
  #if DEBUG
    @State private var hostsFixture = MirrorUIFixture.hostsFixture()
  #endif

  var body: some View {
    #if DEBUG
      if CommandLine.arguments.contains("--mirror-ui-launch-fixture") {
        NavigationStack { LaunchFixtureView() }
      } else if let hostsFixture {
        MirrorAppRoot(hosts: hostsFixture.store, sessions: hostsFixture.sessions)
      } else if let fixture = MirrorUIFixture.paneFixture() {
        NavigationStack { PaneView(session: fixture.session, pane: fixture.pane, host: nil) }
          .environment(sessions)
      } else {
        content
      }
    #else
      content
    #endif
  }

  private var content: some View {
    MirrorAppRoot(hosts: hosts, sessions: sessions)
      .task { await MirrorPushCoordinator.shared.appBecameActive() }
      .onChange(of: scenePhase) { _, phase in
        switch phase {
        case .background: sessions.suspendAll()
        case .active:
          sessions.resumeAll()
          Task { await MirrorPushCoordinator.shared.appBecameActive() }
        default: break
        }
      }
  }
}

/// The paired Hosts, or the demo while it runs (docs-ai 098). Both show the same app; only the
/// store and the sessions, and so the data source, differ.
struct MirrorAppRoot: View {
  let hosts: MirrorHostStore
  let sessions: MirrorHostSessions
  @State private var demo: MirrorDemo?
  @State private var pairsAfterDemo = false

  var body: some View {
    if let demo {
      MirrorRootView(store: demo.store)
        .environment(demo.sessions)
        .environment(
          \.mirrorDemo, MirrorDemoActions(pair: { endDemo(pairing: true) }, exit: { endDemo(pairing: false) }))
    } else {
      MirrorRootView(
        store: hosts, startsPairing: pairsAfterDemo,
        // Only a phone with no paired Mac is offered the demo.
        onTryDemo: hosts.hosts.isEmpty ? { startDemo() } : nil
      )
      .environment(sessions)
    }
  }

  private func startDemo() {
    pairsAfterDemo = false
    demo = MirrorDemo()
  }

  private func endDemo(pairing: Bool) {
    demo?.end()
    pairsAfterDemo = pairing
    demo = nil
  }
}

#if DEBUG
  private struct LaunchFixtureView: View {
    @State private var created: MirrorPaneDescriptor?

    var body: some View {
      if let pane = created {
        Text("Created mirror: \(pane.title)").accessibilityIdentifier("created-mirror")
      } else {
        MirrorLaunchView(execute: MirrorUIFixture.launchCommand) { pane, _ in created = pane }
      }
    }
  }
#endif
