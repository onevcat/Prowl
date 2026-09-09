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
    .popover(isPresented: $isPresented) {
      ScrollView {
        MirrorHostSettingsView(host: mirrors.host, console: mirrors.controlConsole)
      }
      .frame(width: 420).frame(maxHeight: 680)
    }
  }
}

private struct MirrorHostSettingsView: View {
  @Bindable var host: MirrorHost
  @Bindable var console: HostControlConsole
  @State private var copyError: String?
  @State private var copied = false

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
      Divider()
      Toggle("Start AI Control Console", isOn: $console.enabled)
        .help("Optionally launch an Agent that can manage Prowl panes using the bundled CLI")
        .accessibilityIdentifier("remote-mirror-enable-console")
      if console.enabled {
        controlConfiguration
      }
      if let error = console.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      if console.isAlive {
        HStack {
          Button("Open AI Control Console") { console.show() }
            .help("Inspect the control Agent terminal and its errors")
          Button("Restart Console") { console.restart() }
            .disabled(console.isStarting || !console.enabled)
            .help("Restart only the AI control session with the configuration shown above")
        }
      } else if host.isRunning, console.enabled {
        Button(console.isStarting ? "Starting Agent…" : "Start AI Console") { console.start() }
          .disabled(console.isStarting)
          .help("Start the optional control Agent; sharing stays available if startup fails")
      }
      if host.isRunning {
        Label("Listening · \(host.subscriberCount) mirror(s)", systemImage: "checkmark.circle")
        Text("Client: enter this Mac’s reachable IP, port \(host.port), and the pairing key below.")
          .font(.callout).foregroundStyle(.secondary)
        Text(host.pairingKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        Button(copied ? "Copied" : "Copy Pairing Key") {
          NSPasteboard.general.clearContents()
          copied = NSPasteboard.general.setString(host.pairingKey, forType: .string)
          copyError = copied ? nil : "Unable to copy the pairing key."
        }
        .help("Anyone with this key and network access can view and control shared panes.")
        .accessibilityIdentifier("remote-mirror-copy-key")
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
    .frame(width: 420)
    .accessibilityIdentifier("remote-mirror-host-panel")
    .onChange(of: host.pairingKey) { _, _ in
      copied = false
      copyError = nil
    }
  }

  private var controlConfiguration: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker(
        "Agent Profile",
        selection: Binding(
          get: { console.profile.id },
          set: { id in
            if let selected = console.profiles.first(where: { $0.id == id }) {
              console.profile = selected
            }
          })
      ) {
        ForEach(console.profiles) { profile in Text(profile.name).tag(profile.id) }
      }
      TextField(
        "Model (Agent default)",
        text: Binding(
          get: { console.profile.model ?? "" },
          set: {
            console.profile.model = $0.isEmpty ? nil : $0
          }))
      Menu("Suggested models") {
        ForEach(
          AgentRuntimeAdapterRegistry.profileAdapter(for: console.profile.runtime)?.modelSuggestions
            ?? [], id: \.self
        ) { model in
          Button(model) { console.profile.model = model }
        }
      }
      .help("Suggestions are built into Prowl; availability depends on your Agent account")
      Toggle(
        "Bypass approvals",
        isOn: Binding(
          get: { console.profile.executionMode == .unrestricted },
          set: {
            console.profile.executionMode = $0 ? .unrestricted : .standard
          }))
      TextField("Working directory (optional)", text: $console.directory)
      Text("Default: \(HostControlConsole.defaultDirectory.path)")
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      if console.isAlive {
        Text("Configuration changes apply when you restart the console.").font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .disabled(host.isStarting || console.isStarting)
  }
}
