import SwiftUI

/// The app's root (docs-ai 089): pairing until a Host is known, then the agents of the chosen
/// Host. Hosts are switched from the Settings menu or in Settings (docs-ai 098).
struct MirrorRootView: View {
  @Bindable var store: MirrorHostStore
  /// Opens pairing when the view appears, as after leaving the demo with Pair with a Mac.
  var startsPairing = false
  /// Starts the demo from onboarding (docs-ai 098); nil where no demo is offered.
  var onTryDemo: (() -> Void)?
  @Environment(MirrorHostSessions.self) private var sessions
  @State private var path = NavigationPath()
  @State private var showsAdd = false
  @State private var showsSettings = false
  private let router = MirrorNotificationRouter.shared
  /// The Host that a tapped notification selected; its selection change keeps the pane open.
  @State private var notificationHostID: UUID?

  var body: some View {
    Group {
      if let host = store.selectedHost {
        NavigationStack(path: $path) {
          AgentsView(
            host: host, store: store, path: $path,
            onAddHost: { showsAdd = true }, onOpenSettings: { showsSettings = true }
          )
          .id(host.id)
          .navigationDestination(for: MirrorPaneRoute.self) { route in
            PaneView(route: route, session: sessions.makePaneSession(route.host))
          }
        }
      } else {
        MirrorOnboardingView(onAdd: { showsAdd = true }, onTryDemo: onTryDemo)
      }
    }
    .task { if startsPairing { showsAdd = true } }
    .sheet(isPresented: $showsAdd) {
      AddHostView(store: store) { host in
        showsAdd = false
        // A Host paired again has a new credential; its open roster connection holds the old one.
        sessions.forget(host.id)
        sessions.session(for: host).start()
        store.select(host.id)
        path = NavigationPath()
      }
    }
    .sheet(isPresented: $showsSettings) {
      MirrorSettingsView(store: store) {
        Task { @MainActor in showsAdd = true }
      }
    }
    .onChange(of: store.selectedHost?.id) { _, new in
      if new != nil, new == notificationHostID {
        notificationHostID = nil
      } else {
        path = NavigationPath()
      }
    }
    .task(id: router.pending) { await openNotificationTarget() }
  }

  /// A tapped notification (docs-ai 095 P3f); `MirrorNotificationOpener` decides, this view
  /// applies the result.
  private func openNotificationTarget() async {
    guard let target = router.pending else { return }
    let opener = MirrorNotificationOpener(router: router, store: store, sessions: sessions)
    let outcome = await opener.open(target) { host in
      showsAdd = false
      showsSettings = false
      guard store.selectedHost?.id != host.id else { return }
      path = NavigationPath()
      notificationHostID = host.id
      store.select(host.id)
    }
    switch outcome {
    case .unchanged: break
    case .agents: path = NavigationPath()
    case .pane(let route): path = NavigationPath([route])
    }
  }
}
