import ComposableArchitecture
import SwiftUI

/// The Remote Mirror tab (docs-ai 091). While the alpha switch is off, it shows the switch only.
/// The groups are named by direction: connections to this Mac, and connections to another Mac.
struct RemoteMirrorSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @Environment(RemoteMirrorStore.self) private var mirrors
  @State private var sheet: MirrorSettingsSheet?
  @State private var interfaces: [MirrorNetworkInterface] = []
  @State private var deviceToRevoke: MirrorPairedDevice?
  @State private var revokeAllPresented = false
  @State private var mirrorToDisconnect: MirrorDisconnectTarget?
  @State private var hostToRename: MirrorKnownHost?
  @State private var alias = ""

  private enum MirrorSettingsSheet: Identifiable {
    case pairing
    case connect(MirrorKnownHost?)

    var id: String {
      switch self {
      case .pairing: "pairing"
      case .connect(let known): "connect:" + (known?.id ?? "")
      }
    }
  }

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $store.remoteMirrorEnabled) {
          HStack(spacing: 6) {
            Text("Enable Remote Mirror")
            Text("Alpha")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.quaternary, in: .capsule)
              .accessibilityLabel("Alpha feature")
          }
          Text(
            """
            See and control the Prowl terminals of this Mac from Prowl Mirror on an iPhone, or from \
            Prowl on another Mac, on the same network. This feature is in alpha and can change \
            between releases.
            """)
        }
        .help("Show the Remote Mirror button in the toolbar and let paired devices connect to this Mac")
        .accessibilityIdentifier("remote-mirror-enable")
      }
      if store.remoteMirrorEnabled {
        ConnectToThisMacSection(
          host: mirrors.host, startsOnLaunch: $store.remoteMirrorStartsHostOnLaunch, interfaces: interfaces)
        devicesSection
        anotherMacSection
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onChange(of: store.remoteMirrorEnabled, initial: true) { _, enabled in
      guard enabled else { return }
      // Secure storage is read only after the user opens this tab with the feature on.
      interfaces = MirrorHostAddresses.current()
      mirrors.host.loadDevicesIfNeeded()
      mirrors.knownHosts.importLegacyIfNeeded()
    }
    .sheet(item: $sheet) { destination in
      switch destination {
      case .pairing:
        MirrorPairingView(host: mirrors.host) { sheet = nil }
      case .connect(let known):
        AddRemoteMirrorView(dismiss: { sheet = nil }, savedHost: known)
      }
    }
    .confirmationDialog(
      "Revoke \(deviceToRevoke?.name ?? "this device")?",
      isPresented: Binding(get: { deviceToRevoke != nil }, set: { if !$0 { deviceToRevoke = nil } }),
      presenting: deviceToRevoke
    ) { device in
      Button("Revoke", role: .destructive) { mirrors.host.revoke(device.id) }
    } message: { _ in
      Text("The device is disconnected and must pair again before it can mirror this Mac.")
    }
    .alert("Revoke All Devices?", isPresented: $revokeAllPresented) {
      Button("Revoke All Devices", role: .destructive) { mirrors.host.revokeAllDevices() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        """
        All devices will be disconnected and must pair again. \
        Saved connections and the current pairing code will no longer work. Local terminals keep running.
        """
      )
    }
    .mirrorDisconnectAlert($mirrorToDisconnect, host: mirrors.host)
    .alert(
      "Rename Mac",
      isPresented: Binding(get: { hostToRename != nil }, set: { if !$0 { hostToRename = nil } }),
      presenting: hostToRename
    ) { known in
      TextField("Name", text: $alias, prompt: Text(known.endpointID))
      Button("Save") { mirrors.knownHosts.rename(known.id, alias: alias) }
      Button("Cancel", role: .cancel) {}
    } message: { known in
      Text("The name is shown instead of \(known.endpointID) on this Mac only.")
    }
  }

  private var devicesSection: some View {
    let host = mirrors.host
    return Section {
      if let failure = host.deviceListError {
        // A failed read is not an empty list: saved devices can still have access.
        HStack {
          Text(failure).foregroundStyle(.red).textSelection(.enabled)
          Spacer()
          Button("Try Again") { host.loadDevicesIfNeeded() }
            .help("Read the paired devices from secure storage again")
            .accessibilityIdentifier("remote-mirror-retry-device-list")
        }
      } else if host.devices.isEmpty {
        Text("No paired devices.").foregroundStyle(.secondary)
      }
      ForEach(host.devices) { device in
        MirrorDeviceRow(
          host: host, device: device, revoke: { deviceToRevoke = device },
          disconnect: { mirrorToDisconnect = $0 })
      }
      HStack {
        Button("Add a Device…") { sheet = .pairing }
          .help("Show a single-use pairing code with a 60-second expiry")
          .accessibilityIdentifier("remote-mirror-add-device")
        Spacer()
        if !host.devices.isEmpty {
          Button("Revoke All Devices…", role: .destructive) { revokeAllPresented = true }
            .help("Disconnect all devices and require fresh pairing, including devices currently offline")
            .accessibilityIdentifier("remote-mirror-revoke-all-devices")
        }
      }
    } header: {
      Text("Paired Devices")
    }
  }

  private var anotherMacSection: some View {
    let known = mirrors.knownHosts
    return Section {
      ForEach(known.hosts) { saved in
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(saved.displayName).lineLimit(1)
            Text(caption(for: saved)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer()
          Button("Connect") { sheet = .connect(saved) }
            .help("Connect to this Mac and select a pane")
          Menu {
            Button("Rename…") {
              alias = saved.alias ?? ""
              hostToRename = saved
            }
            Button("Forget", role: .destructive) { known.forget(saved.id) }
          } label: {
            Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .help("Rename this Mac or forget its saved access")
        }
      }
      if known.hosts.isEmpty, known.notice == nil {
        Text("No saved Macs.").foregroundStyle(.secondary)
      }
      if let notice = known.notice {
        Text(notice).font(.caption).foregroundStyle(.secondary)
        if !known.hasImportedLegacy {
          Button("Try Again") { known.importLegacyIfNeeded() }
            .help("Read previously saved Macs from secure storage again")
        }
      }
      Button("Connect to a Mac…") { sheet = .connect(nil) }
        .help("Enter the address of another Mac and its pairing code")
        .accessibilityIdentifier("remote-mirror-connect-to-mac")
    } header: {
      MirrorSettingsHeader(
        title: "Connect to Another Mac",
        subtitle: "See and control the Prowl terminals of another Mac from this Mac.")
    }
  }

  private func caption(for known: MirrorKnownHost) -> String {
    var parts: [String] = []
    if known.alias != nil { parts.append(known.endpointID) }
    if let connected = known.lastConnectedAt {
      parts.append(String(localized: "Last connected \(connected.formatted(.relative(presentation: .named)))"))
    } else {
      parts.append(String(localized: "Never connected"))
    }
    return parts.joined(separator: " · ")
  }
}

/// The listener: status, start and stop, start with the app, address and port.
private struct ConnectToThisMacSection: View {
  @Bindable var host: MirrorHost
  @Binding var startsOnLaunch: Bool
  let interfaces: [MirrorNetworkInterface]

  var body: some View {
    let options = MirrorListenOption.options(interfaces: interfaces, current: host.address)
    // Static text while listening: the address and port apply at the next start.
    let editable = !(host.isRunning || host.isStarting)
    Section {
      LabeledContent("Status") {
        HStack {
          Text(MirrorHostStatus.text(for: host)).foregroundStyle(.secondary)
          if host.isRunning || host.isStarting {
            Button("Stop Listening", role: .destructive) { host.stop() }
              .help("Disconnect all devices and stop listening; local terminals keep running")
          } else {
            Button("Start Listening") { host.start() }
              .help("Let paired devices connect to this Mac")
          }
        }
      }
      .accessibilityIdentifier("remote-mirror-listener-status")
      Toggle("Start listening when Prowl opens", isOn: $startsOnLaunch)
        .help("Start the listener at launch, so paired devices can connect without a click here")
      if editable {
        Picker("Listen on", selection: $host.address) {
          ForEach(options) { Text($0.label).tag($0.address) }
        }
        .help("Which of this Mac’s addresses accept connections")
        TextField("Port", text: $host.port)
          .help("The network port that paired devices connect to")
      } else {
        LabeledContent("Listen on", value: options.first { $0.address == host.address }?.label ?? host.address)
        LabeledContent("Port", value: host.port)
      }
      if let error = host.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
    } header: {
      MirrorSettingsHeader(
        title: "Connect to This Mac",
        subtitle: "Let a paired iPhone or another Mac see and control the Prowl terminals of this Mac.")
    }
  }
}

private struct MirrorSettingsHeader: View {
  let title: LocalizedStringKey
  let subtitle: LocalizedStringKey

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
      Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
    }
  }
}
