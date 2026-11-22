import SwiftUI

/// The app's root (docs-ai 089): pairing until a Host is known, then the agents of the chosen
/// Host. Hosts are switched from the Agents title menu, never from a screen of their own.
struct MirrorRootView: View {
  @Bindable var store: MirrorHostStore
  @Environment(MirrorHostSessions.self) private var sessions
  @State private var path = NavigationPath()
  @State private var showsAdd = false
  @State private var showsHosts = false
  private let router = MirrorNotificationRouter.shared
  /// The Host that a tapped notification selected; its selection change keeps the pane open.
  @State private var notificationHostID: UUID?

  var body: some View {
    Group {
      if let host = store.selectedHost {
        NavigationStack(path: $path) {
          AgentsView(
            host: host, store: store, path: $path,
            onAddHost: { showsAdd = true }, onManageHosts: { showsHosts = true }
          )
          .id(host.id)
          .navigationDestination(for: MirrorPaneRoute.self) { route in
            PaneView(route: route, session: sessions.makePaneSession(route.host))
          }
        }
      } else {
        MirrorOnboardingView { showsAdd = true }
      }
    }
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
    .sheet(isPresented: $showsHosts) {
      HostsManagerView(store: store) {
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

  /// A tapped notification (docs-ai 095 P3f): show its Host, connect if needed, and open the
  /// pane once the Host lists it. A pane that is gone leaves the agents list in view.
  private func openNotificationTarget() async {
    guard let target = router.pending else { return }
    defer { router.pending = nil }
    guard let host = store.hosts.first(where: { $0.hostID == target.hostID }) else { return }
    showsAdd = false
    showsHosts = false
    if store.selectedHost?.id != host.id {
      path = NavigationPath()
      notificationHostID = host.id
      store.select(host.id)
    }
    let session = sessions.session(for: host)
    if case .failed = session.status { session.retry() } else { session.start() }
    // The roster arrives within the connect timeout, or the connection failed.
    let deadline = ContinuousClock.now + MirrorHostSession.connectTimeoutDuration
    while session.status != .ready, ContinuousClock.now < deadline {
      if case .failed = session.status { return }
      try? await Task.sleep(for: .milliseconds(200))
      if Task.isCancelled { return }
    }
    guard let route = MirrorNotificationRouter.route(for: target, host: host, panes: session.panes) else { return }
    path = NavigationPath([route])
  }
}

/// The first launch: what the app does and how to pair, with the QR code as the main path.
struct MirrorOnboardingView: View {
  let onAdd: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
      Image("ProwlMark")
        .resizable()
        .scaledToFit()
        .frame(width: 112, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .accentColor.opacity(0.35), radius: 24, y: 10)
        .accessibilityHidden(true)
      Text("Prowl Mirror")
        .font(.largeTitle.bold())
        .padding(.top, 28)
      Text("Follow the agents on your Mac, answer them, and start new ones — from here.")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.top, 8)
        .padding(.horizontal, 32)
      VStack(alignment: .leading, spacing: 16) {
        step("macbook", "On the Mac, open the Remote Mirror button in the Prowl toolbar.")
        step("qrcode", "Choose Add a Device to show a pairing code.")
        step("iphone", "Scan the code here, or type the address and code.")
      }
      .padding(.top, 36)
      .padding(.horizontal, 36)
      Spacer()
      Button(action: onAdd) {
        Label("Pair with a Mac", systemImage: "qrcode.viewfinder")
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
      }
      .buttonStyle(.glassProminent)
      .controlSize(.large)
      .padding(.horizontal, 24)
      .padding(.bottom, 24)
      .accessibilityIdentifier("add-host")
      .help("Pair with a Mac running Prowl")
    }
    .frame(maxWidth: 520)
    .frame(maxWidth: .infinity)
  }

  private func step(_ symbol: String, _ text: LocalizedStringKey) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 28)
      Text(text).font(.callout)
    }
  }
}
