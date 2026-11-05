import SwiftUI

/// The app's root (docs-ai 089): pairing until a Host is known, then the agents of the chosen
/// Host. Hosts are switched from the Agents title menu, never from a screen of their own.
struct MirrorRootView: View {
  @Bindable var store: MirrorHostStore
  @Environment(MirrorHostSessions.self) private var sessions
  @State private var path = NavigationPath()
  @State private var showsAdd = false
  @State private var showsHosts = false

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
        store.select(host.id)
        path = NavigationPath()
      }
    }
    .sheet(isPresented: $showsHosts) {
      HostsManagerView(store: store) {
        Task { @MainActor in showsAdd = true }
      }
    }
    .onChange(of: store.selectedHost?.id) { _, _ in path = NavigationPath() }
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
