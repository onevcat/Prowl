import ComposableArchitecture
import SwiftUI

struct MirrorHostButton: View {
  @Environment(RemoteMirrorStore.self) private var mirrors
  @Environment(ToolbarPopoverCoordinator.self) private var popovers
  @Dependency(FeatureFlags.self) private var featureFlags
  @State private var sheet: MirrorSheet?
  @State private var connectionToOpen: MirrorKnownHost?

  private enum MirrorSheet: String, Identifiable {
    case pairing, connect
    var id: String { rawValue }
  }

  private var status: String {
    if !mirrors.host.isRunning { return "Host off" }
    return mirrors.host.subscriberCount == 0 ? "Host listening" : "Host mirroring"
  }

  private var tint: Color {
    guard mirrors.host.isRunning else { return .secondary }
    return mirrors.host.subscriberCount == 0 ? .blue.opacity(0.65) : .green.opacity(0.65)
  }

  var body: some View {
    if featureFlags.remoteMirror {
      let isPresented = popovers.presented == .mirror
      Button {
        popovers.toggle(.mirror)
        // Keychain is read only after a click; hover previews stay in memory.
        if popovers.presented == .mirror { mirrors.knownHosts.importLegacyIfNeeded() }
      } label: {
        Image(systemName: "network").foregroundStyle(tint)
      }
      .help("Remote Mirror — \(status). Hover to preview or click to keep open.")
      .accessibilityLabel("Remote Mirror — \(status)")
      .accessibilityIdentifier("remote-mirror-host-button")
      .onHover { if sheet == nil { popovers.hoverButton(.mirror, hovering: $0) } }
      .popover(
        isPresented: Binding(
          get: { isPresented },
          set: {
            if !$0 {
              popovers.dismiss(.mirror)
            }
          }
        )
      ) {
        MirrorPopover {
          MirrorSettingsView(
            host: mirrors.host,
            interact: { popovers.pin(.mirror) },
            pair: { present(.pairing) },
            connect: {
              connectionToOpen = nil
              present(.connect)
            },
            reconnect: {
              connectionToOpen = $0
              present(.connect)
            }
          )
          .fixedSize(horizontal: false, vertical: true)
        }
        .onHover { popovers.hoverPopover(.mirror, hovering: $0) }
      }
      .background {
        Color.clear
          .sheet(item: $sheet) { destination in
            switch destination {
            case .pairing:
              MirrorPairingView(host: mirrors.host) { sheet = nil }
            case .connect:
              AddRemoteMirrorView(dismiss: { sheet = nil }, savedHost: connectionToOpen)
            }
          }
      }
      .onDisappear {
        popovers.dismiss(.mirror)
      }
    }
  }

  private func present(_ destination: MirrorSheet) {
    popovers.dismiss(.mirror)
    sheet = destination
  }
}

private struct MirrorPopover<Content: View>: View {
  @ViewBuilder let content: () -> Content
  @State private var contentHeight: CGFloat = 360

  var body: some View {
    ScrollView {
      content()
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          contentHeight = $0
        }
    }
    .frame(width: 460, height: min(contentHeight, max(240, (NSScreen.main?.visibleFrame.height ?? 840) - 180)))
    .transaction { $0.animation = nil }
  }
}

private struct MirrorSettingsView: View {
  @Environment(RemoteMirrorStore.self) private var mirrors
  @Bindable var host: MirrorHost
  let interact: () -> Void
  let pair: () -> Void
  let connect: () -> Void
  let reconnect: (MirrorKnownHost) -> Void
  @State private var interfaces: [MirrorNetworkInterface] = []
  @State private var deviceToRevoke: MirrorPairedDevice?
  @State private var mirrorToDisconnect: DisconnectTarget?

  private struct DisconnectTarget {
    let subscriptionID: UUID
    let paneTitle: String
    let deviceName: String
  }

  @State private var hostToRename: MirrorKnownHost?
  @State private var alias = ""

  private var listenOptions: [ListenOption] {
    var options = [ListenOption(address: MirrorHostAddresses.allIPv4, label: "All interfaces (0.0.0.0)")]
    for interface in interfaces where interface.isIPv4 && !interface.isLoopback {
      options.append(ListenOption(address: interface.address, label: interface.label + " · " + interface.address))
    }
    options.append(ListenOption(address: MirrorHostAddresses.loopback, label: "This Mac only (127.0.0.1)"))
    if !options.contains(where: { $0.address == host.address }) {
      options.append(ListenOption(address: host.address, label: "Custom · " + host.address))
    }
    return options
  }

  private var hostStatus: String {
    if host.isStarting { return "Starting…" }
    guard host.isRunning else { return "Host is off" }
    return "Listening · " + Self.mirrors(host.subscriberCount)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        Text("Remote Mirror").font(.headline)
        Spacer()
        Text(hostStatus).font(.subheadline).foregroundStyle(.secondary)
      }
      hostSection
      Divider()
      clientSection
    }
    .padding(20)
    .frame(width: 460)
    .accessibilityIdentifier("remote-mirror-host-panel")
    .onAppear { interfaces = MirrorHostAddresses.current() }
    .onChange(of: host.address) { _, _ in interact() }
    .onChange(of: host.port) { _, _ in interact() }
    .confirmationDialog(
      "Revoke \(deviceToRevoke?.name ?? "this device")?",
      isPresented: Binding(get: { deviceToRevoke != nil }, set: { if !$0 { deviceToRevoke = nil } }),
      presenting: deviceToRevoke
    ) { device in
      Button("Revoke", role: .destructive) { host.revoke(device.id) }
    } message: { _ in
      Text("The device is disconnected and must pair again before it can mirror this Mac.")
    }
    .alert(
      "Disconnect Mirror?",
      isPresented: Binding(get: { mirrorToDisconnect != nil }, set: { if !$0 { mirrorToDisconnect = nil } }),
      presenting: mirrorToDisconnect
    ) { target in
      Button("Disconnect", role: .destructive) { host.disconnect(subscriptionID: target.subscriptionID) }
      Button("Cancel", role: .cancel) {}
    } message: { target in
      Text(
        "Disconnect \(target.deviceName) from \(target.paneTitle)? "
          + "The terminal keeps running. The device stays paired and can reconnect.")
    }
    .alert(
      "Rename Host",
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

  private var hostSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Host").font(.subheadline.weight(.semibold))
      Text("Let paired Prowl apps on your network mirror this Mac’s terminals.")
        .foregroundStyle(.secondary)
      // Static text while running: a disabled, still-focused field keeps its selection highlight.
      let editable = !(host.isRunning || host.isStarting)
      // Center rows: the pop-up button reports no usable text baseline, so baseline alignment floats the label.
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          Text("Listen on").gridColumnAlignment(.trailing)
          if editable {
            // SwiftUI's menu picker keeps its intrinsic width and grows after its first open;
            // an AppKit pop-up button fills the row from the start.
            ListenAddressPopUp(options: listenOptions, selection: $host.address)
              .frame(maxWidth: .infinity)
              .help("Which of this Mac’s addresses accept connections")
              .accessibilityLabel("Listen on")
          } else {
            Text(listenOptions.first { $0.address == host.address }?.label ?? host.address)
          }
        }
        GridRow {
          Text("Port").gridColumnAlignment(.trailing)
          if editable {
            TextField("Port", text: $host.port)
              .labelsHidden()
              .frame(width: 100)
              .help("The network port other Prowl apps connect to")
          } else {
            Text(host.port)
          }
        }
      }
      HStack {
        Spacer()
        if host.isRunning || host.isStarting {
          Button("Add a Device…", action: pair)
            .help("Show a single-use pairing code with a 60-second expiry")
            .disabled(host.isStarting)
          Button("Stop Host", role: .destructive) {
            interact()
            host.stop()
          }
          .help("Disconnect mirrors and stop listening; local terminals keep running")
        } else {
          Button("Start Host") {
            interact()
            host.start()
          }
          .buttonStyle(.borderedProminent)
          .help("Allow paired Prowl devices to connect to this Mac")
        }
      }
      ForEach(host.devices) { device in
        VStack(alignment: .leading, spacing: 4) {
          let panes = host.mirroredPanes(for: device.id)
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
              Text(device.name).lineLimit(1)
              Text(deviceStatus(device, mirrorCount: panes.count)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revoke", role: .destructive) {
              interact()
              deviceToRevoke = device
            }
            .help("Disconnect this device and require it to pair again")
          }
          ForEach(panes) { pane in
            HStack(spacing: 6) {
              Circle().fill(.green).frame(width: 6, height: 6)
                .accessibilityHidden(true)
              Text(pane.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help(pane.title + "\n" + pane.directory)
                .accessibilityLabel("Mirroring \(pane.title)")
              Spacer(minLength: 4)
              Button {
                guard let subscriptionID = host.subscriptionID(for: pane.id, deviceID: device.id) else { return }
                interact()
                mirrorToDisconnect = DisconnectTarget(
                  subscriptionID: subscriptionID, paneTitle: pane.title, deviceName: device.name)
              } label: {
                Image(systemName: "personalhotspot.slash")
                  .font(.caption)
                  .symbolRenderingMode(.monochrome)
                  .foregroundStyle(.red)
                  .frame(width: 18, height: 18)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.borderless)
              .help("Disconnect this mirror; keep the device paired and the terminal running")
              .accessibilityLabel("Disconnect mirror of \(pane.title) from \(device.name)")
              .accessibilityIdentifier("disconnect-mirror-\(pane.id)")
            }
          }
        }
      }
      if let error = host.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      Text("Closing this panel keeps Host running.").font(.caption).foregroundStyle(.secondary)
    }
  }

  private var clientSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Client").font(.subheadline.weight(.semibold))
      Text("Mirror a terminal pane from Prowl on another Mac.")
        .foregroundStyle(.secondary)
      ForEach(mirrors.knownHosts.hosts) { known in
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(known.displayName).lineLimit(1)
            Text(knownHostCaption(known)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer()
          Button("Connect") { reconnect(known) }
            .help("Connect to this Host and select a pane")
          Menu {
            Button("Rename…") {
              interact()
              alias = known.alias ?? ""
              hostToRename = known
            }
            Button("Forget", role: .destructive) {
              interact()
              mirrors.knownHosts.forget(known.id)
            }
          } label: {
            Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .help("Rename this Host or forget its saved access")
        }
      }
      if mirrors.knownHosts.hosts.isEmpty, mirrors.knownHosts.hasImportedLegacy, mirrors.knownHosts.notice == nil {
        Text("No paired Hosts yet.").font(.caption).foregroundStyle(.secondary)
      }
      if !mirrors.knownHosts.hasImportedLegacy, mirrors.knownHosts.notice == nil {
        Text("Hosts paired with an earlier version appear after you click the Remote Mirror button.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let notice = mirrors.knownHosts.notice {
        Text(notice).font(.caption).foregroundStyle(.secondary)
        if !mirrors.knownHosts.hasImportedLegacy {
          Button("Try Again") {
            interact()
            mirrors.knownHosts.importLegacyIfNeeded()
          }
          .help("Read previously paired Hosts from secure storage again")
        }
      }
      Button("Connect to a New Host…", action: connect)
        .help("Enter another Mac’s address and its pairing code")
    }
  }

  private func deviceStatus(_ device: MirrorPairedDevice, mirrorCount: Int) -> String {
    if host.isOnline(device.id) { return "Connected · " + Self.mirrors(mirrorCount) }
    guard let seen = device.lastSeen else { return "Paired · never connected" }
    return "Last seen " + seen.formatted(.relative(presentation: .named))
  }

  private func knownHostCaption(_ known: MirrorKnownHost) -> String {
    var parts: [String] = []
    if known.alias != nil { parts.append(known.endpointID) }
    if let connected = known.lastConnectedAt {
      parts.append("Last connected " + connected.formatted(.relative(presentation: .named)))
    } else {
      parts.append("Never connected")
    }
    return parts.joined(separator: " · ")
  }

  private static func mirrors(_ count: Int) -> String {
    count == 1 ? "1 mirror" : "\(count) mirrors"
  }
}

private struct MirrorPairingView: View {
  @Bindable var host: MirrorHost
  let dismiss: () -> Void
  @State private var hasRequestedCode = false
  @State private var copied = false
  @State private var copyError: String?
  @State private var interfaces: [MirrorNetworkInterface] = []
  @State private var dismissTask: Task<Void, Never>?

  private var reachable: [MirrorNetworkInterface] {
    MirrorHostAddresses.reachable(listenAddress: host.address, interfaces: interfaces)
  }

  private var localName: String? {
    guard host.address != MirrorHostAddresses.loopback else { return nil }
    return MirrorHostAddresses.localHostName()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Add a Device").font(.title2.bold())
      if let paired = host.lastPairedDevice {
        Label("Paired with \(paired.name)", systemImage: "checkmark.circle.fill")
          .font(.title3).foregroundStyle(.green)
        Text("The device can now connect to this Mac and select a pane.").foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        // Sheets propose no height; without fixedSize multi-line text collapses to one truncated line.
        Text(
          "On the other device, open Remote Mirror → Client → Connect to a New Host. "
            + "Enter one of these addresses with the port, then the code below."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        addresses
        code
      }
      if let error = copyError ?? host.error {
        Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Button(host.lastPairedDevice == nil ? "Cancel" : "Done") {
          host.cancelPairing()
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .help("Close this window and invalidate the unused code")
        Spacer()
        if host.lastPairedDevice == nil {
          if !host.isRunning && !host.isStarting {
            Button("Start Host") { host.start() }
              .buttonStyle(.borderedProminent)
              .help("Start listening, then create a pairing code")
          } else {
            Button("Refresh Code") { host.addDevice() }
              .disabled(host.isStarting || !host.isRunning)
              .help("Invalidate the old code and create a new 60-second code")
          }
        }
      }
    }
    .padding(24).frame(width: 440)
    .onAppear { interfaces = MirrorHostAddresses.current() }
    .onChange(of: host.isStarting, initial: true) { _, starting in
      guard !hasRequestedCode, !starting, host.isRunning else { return }
      hasRequestedCode = true
      host.addDevice()
    }
    .onChange(of: host.pairingKey) { _, _ in
      copied = false
      copyError = nil
    }
    .onChange(of: host.lastPairedDevice) { _, paired in
      guard paired != nil else { return }
      dismissTask?.cancel()
      dismissTask = Task {
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled else { return }
        dismiss()
      }
    }
    .onDisappear {
      dismissTask?.cancel()
      host.cancelPairing()
    }
  }

  private var addresses: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("This Mac’s address").font(.subheadline.weight(.semibold))
      // A grid lets the label column fit names like Thunderbolt Bridge without a fixed width.
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
        if let localName {
          addressRow(label: "Name", value: localName + ":" + host.port)
        }
        ForEach(reachable) { interface in
          addressRow(label: interface.label, value: interface.address + ":" + host.port)
        }
      }
      if reachable.isEmpty, localName == nil {
        Text("No network address found. Connect this Mac to a network.").font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(
        "Reachable on your local network or VPN. The internet cannot reach this port unless your router forwards it."
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func addressRow(label: String, value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary).lineLimit(1)
      Text(value).font(.body.monospaced()).textSelection(.enabled).lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        copy(value)
      } label: {
        Label("Copy \(value)", systemImage: "doc.on.doc").labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
      .help("Copy \(value)")
    }
  }

  private var code: some View {
    VStack(spacing: 8) {
      if let expires = host.pairingExpiresAt {
        HStack(spacing: 12) {
          Text(host.pairingKey)
            .font(.largeTitle.monospaced().weight(.semibold))
            .textSelection(.enabled)
            .accessibilityIdentifier("remote-mirror-pairing-key")
          Button {
            copy(host.pairingKey)
          } label: {
            Label(copied ? "Copied" : "Copy the pairing code", systemImage: copied ? "checkmark" : "doc.on.doc")
              .labelStyle(.iconOnly)
          }
          .buttonStyle(.borderless)
          .keyboardShortcut("c", modifiers: .command)
          .help("Copy the pairing code (⌘C)")
          .accessibilityIdentifier("remote-mirror-copy-key")
        }
        HStack(spacing: 4) {
          Text("Expires in")
          Text(expires, style: .timer).monospacedDigit()
        }
        .font(.callout).foregroundStyle(.secondary)
      } else if !host.isRunning && !host.isStarting {
        Text("Host is off. Start Host to create a pairing code.").foregroundStyle(.secondary)
      } else if !hasRequestedCode || host.isStarting {
        ProgressView("Preparing pairing…")
      } else {
        Text("The code expired. Refresh to create a new one.").foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    let done = NSPasteboard.general.setString(value, forType: .string)
    copied = done && value == host.pairingKey
    copyError = done ? nil : "Unable to copy to the clipboard."
  }
}

private struct ListenOption: Identifiable {
  let address: String
  let label: String
  var id: String { address }
}

/// AppKit pop-up button: fills the proposed width, which SwiftUI's menu picker does not.
private struct ListenAddressPopUp: NSViewRepresentable {
  let options: [ListenOption]
  @Binding var selection: String

  func makeNSView(context: Context) -> NSPopUpButton {
    let button = NSPopUpButton(frame: .zero, pullsDown: false)
    button.setContentHuggingPriority(.defaultLow, for: .horizontal)
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    button.target = context.coordinator
    button.action = #selector(Coordinator.changed(_:))
    return button
  }

  func updateNSView(_ button: NSPopUpButton, context: Context) {
    context.coordinator.parent = self
    if button.itemTitles != options.map(\.label) {
      button.removeAllItems()
      for option in options {
        button.addItem(withTitle: option.label)
        button.lastItem?.representedObject = option.address
      }
    }
    if let index = options.firstIndex(where: { $0.address == selection }) {
      button.selectItem(at: index)
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  final class Coordinator: NSObject {
    var parent: ListenAddressPopUp
    init(parent: ListenAddressPopUp) { self.parent = parent }

    @objc func changed(_ sender: NSPopUpButton) {
      guard let address = sender.selectedItem?.representedObject as? String else { return }
      parent.selection = address
    }
  }
}
