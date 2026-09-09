import SwiftUI

struct MirrorHostButton: View {
  @Environment(RemoteMirrorStore.self) private var mirrors
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      Label(mirrors.host.isRunning ? "Host Running" : "Start Host", systemImage: "network")
        .foregroundStyle(mirrors.host.isRunning ? Color.green : Color.primary)
    }
    .help("Configure Remote Mirror Host")
    .accessibilityIdentifier("remote-mirror-host-button")
    .popover(isPresented: $isPresented) { MirrorHostSettingsView(host: mirrors.host) }
  }
}

private struct MirrorHostSettingsView: View {
  @Bindable var host: MirrorHost

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Remote Mirror Host").font(.title2.bold())
      Text("Share existing panes with another Prowl. Local input stays available.")
        .foregroundStyle(.secondary)
      Form {
        TextField("Listen IP", text: $host.address)
          .help("Use 0.0.0.0 for all IPv4 interfaces, or this Mac’s local IP.")
        TextField("Port", text: $host.port)
      }
      .disabled(host.isRunning || host.isStarting)
      if host.isRunning {
        Label("Listening · \(host.subscriberCount) mirror(s)", systemImage: "checkmark.circle")
        Text("Client: enter this Mac’s reachable IP, port \(host.port), and the pairing key below.")
          .font(.callout).foregroundStyle(.secondary)
        Text(host.pairingKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        ShareLink("Copy or Share Pairing Key", item: host.pairingKey)
          .help("Anyone with this key and network access can view and control shared panes.")
      }
      if let error = host.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Text("Closing this panel keeps Host running.").font(.caption).foregroundStyle(.secondary)
        Spacer()
        if host.isRunning || host.isStarting {
          Button("Stop Host", role: .destructive) { host.stop() }
        } else {
          Button("Start Host") { host.start() }.buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(24)
    .frame(width: 420)
    .accessibilityIdentifier("remote-mirror-host-panel")
  }
}
