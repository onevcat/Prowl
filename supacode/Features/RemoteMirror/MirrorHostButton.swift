import ComposableArchitecture
import SwiftUI

struct MirrorHostButton: View {
  @Environment(RemoteMirrorStore.self) private var mirrors
  @Environment(ToolbarPopoverCoordinator.self) private var popovers
  @Dependency(FeatureFlags.self) private var featureFlags
  @State private var panelHeight: CGFloat = 700

  var body: some View {
    if featureFlags.remoteMirror {
      Button {
        if popovers.presented != .mirror {
          panelHeight = min(760, max(300, (NSScreen.main?.visibleFrame.height ?? 840) - 140))
        }
        popovers.toggle(.mirror)
      } label: {
        Label(mirrors.host.isRunning ? "Host Running" : "Start Host", systemImage: "network")
          .foregroundStyle(mirrors.host.isRunning ? Color.green : Color.primary)
      }
      .help("Configure Remote Mirror Host")
      .accessibilityIdentifier("remote-mirror-host-button")
      .popover(
        isPresented: Binding(
          get: { popovers.presented == .mirror },
          set: { if !$0 { popovers.dismiss(.mirror) } }
        )
      ) {
        ScrollView {
          MirrorHostSettingsView(host: mirrors.host)
            .fixedSize(horizontal: false, vertical: true)
        }
        // Keep the native popover size stable while Host state change.
        // Content-driven resizing can reenter AppKit's animated layout on macOS 26.
        .frame(width: 460, height: panelHeight)
      }
      .onDisappear { popovers.dismiss(.mirror) }
    }
  }
}

private struct MirrorHostSettingsView: View {
  @Bindable var host: MirrorHost
  @State private var copyError: String?
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Remote Mirror Host").font(.title2.bold())
      Text("Share panes and let clients launch your Agent Profiles. Local input stays available.")
        .foregroundStyle(.secondary)
      Form {
        TextField("Listen IP", text: $host.address)
          .help("Use 0.0.0.0 for all IPv4 interfaces, or this Mac’s local IP.")
        TextField("Port", text: $host.port)
      }
      .disabled(host.isRunning || host.isStarting)
      if host.isRunning {
        Label("Listening · \(host.subscriberCount) mirror(s)", systemImage: "checkmark.circle")
        Text(
          "Paired devices reconnect without a code. To pair a new device, open a 60-second window."
        )
        .font(.callout).foregroundStyle(.secondary)
        Button("Add a Device") { host.addDevice() }
          .help("Create a single-use pairing code valid for 60 seconds")
          .disabled(host.isStarting)
        if let expires = host.pairingExpiresAt {
          Text(host.pairingKey).font(.system(.title2, design: .monospaced)).textSelection(.enabled)
          Text(expires, style: .timer).font(.caption)
          Button(copied ? "Copied" : "Copy Pairing Code") {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(host.pairingKey, forType: .string)
            copyError = copied ? nil : "Unable to copy the pairing code."
          }
          .help("Copy the single-use code for the device you are pairing")
          .accessibilityIdentifier("remote-mirror-copy-key")
        }
        ForEach(host.devices) { device in
          HStack {
            VStack(alignment: .leading) {
              Text(device.name).lineLimit(1)
              Text(host.isOnline(device.id) ? "Online" : "Offline").font(.caption).foregroundStyle(
                .secondary)
            }
            Spacer()
            Button("Revoke", role: .destructive) { host.revoke(device.id) }
              .help("Disconnect this device and require it to pair again")
          }
        }
        if let copyError { Text(copyError).foregroundStyle(.red) }
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
    .frame(width: 460)
    .accessibilityIdentifier("remote-mirror-host-panel")
    .onChange(of: host.pairingKey) { _, _ in
      copied = false
      copyError = nil
    }
  }

}
