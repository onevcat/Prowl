import SwiftUI

/// Hosts → panes → one pane (docs-ai 088). DEBUG fixture arguments replace the network with
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
        HostsView(store: hostsFixture.store).environment(hostsFixture.sessions)
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
    HostsView(store: hosts)
      .environment(sessions)
      .onChange(of: scenePhase) { _, phase in
        switch phase {
        case .background: sessions.suspendAll()
        case .active: sessions.resumeAll()
        default: break
        }
      }
  }
}

#if DEBUG
  private struct LaunchFixtureView: View {
    @State private var created: MirrorPaneDescriptor?

    var body: some View {
      if let pane = created {
        Text("Created mirror: \(pane.title)").accessibilityIdentifier("created-mirror")
      } else {
        MirrorLaunchView(execute: MirrorUIFixture.launchCommand) { created = $0 }
      }
    }
  }
#endif
