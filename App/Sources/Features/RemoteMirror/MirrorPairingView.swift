import SwiftUI

/// The sheet that shows a single-use pairing code for a new device.
struct MirrorPairingView: View {
  @Bindable var host: MirrorHost
  let dismiss: () -> Void
  @State private var qrAddress = ""
  @State private var hasRequestedCode = false
  @State private var copied = false
  @State private var copyError: String?
  @State private var interfaces: [MirrorNetworkInterface] = []
  @State private var dismissTask: Task<Void, Never>?
  @State private var kind: DeviceKind = .iPhone

  /// The device to pair. Each page shows the one step for that device (docs-ai 091).
  private enum DeviceKind: Hashable {
    case iPhone, mac
  }

  private var reachable: [MirrorNetworkInterface] {
    MirrorHostAddresses.reachable(listenAddress: host.address, interfaces: interfaces)
  }

  private var pairingAddress: String? {
    let choices = reachable.filter { !$0.isLoopback && $0.address != "::1" }
    return choices.first(where: { $0.address == qrAddress })?.address ?? choices.first?.address
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
        Picker("Device to pair", selection: $kind) {
          Text("iPhone").tag(DeviceKind.iPhone)
          Text("Mac").tag(DeviceKind.mac)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Choose the device that you want to pair with this Mac")
        .accessibilityIdentifier("remote-mirror-pairing-device-kind")
        // Sheets propose no height; without fixedSize multi-line text collapses to one truncated line.
        Group {
          switch kind {
          case .iPhone:
            Text("On the iPhone, open Prowl Mirror, tap Scan QR Code, and point the camera at this code.")
          case .mac:
            Text(
              """
              On the other Mac, open Settings → Remote Mirror → Connect to Another Mac → Connect to a Mac…, \
              then paste the connection details into any field.
              """)
          }
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        code
        connection
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
            Button("Start Listening") { host.start() }
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
    .onChange(of: qrAddress) { _, _ in copied = false }
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

  private var connection: some View {
    let choices = reachable.filter { !$0.isLoopback && $0.address != "::1" }
    let selected = pairingAddress
    return VStack(spacing: 8) {
      if let expires = host.pairingExpiresAt, let selected {
        if choices.count > 1 {
          Picker("Connection address", selection: Binding(get: { selected }, set: { qrAddress = $0 })) {
            ForEach(choices) { item in
              Text("\(item.label): \(item.address)").tag(item.address)
            }
          }
          .help("Choose the Wi-Fi or VPN address that the other device can reach")
        }
        Text("\(selected):\(host.port)").font(.body.monospaced()).textSelection(.enabled)
        switch kind {
        case .iPhone:
          MirrorPairingQRCode(
            address: selected, port: host.port, code: host.pairingKey, expires: expires)
        case .mac:
          Button(copied ? "Copied" : "Copy Connection Details", systemImage: copied ? "checkmark" : "doc.on.doc") {
            copyConnectionDetails()
          }
          .keyboardShortcut("c", modifiers: .command)
          .help("Copy the address, port and pairing code together (⌘C)")
          .accessibilityIdentifier("remote-mirror-copy-connection")
        }
      } else if selected == nil {
        Text("No network address is available for pairing. Listen on a Wi-Fi or VPN interface.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var code: some View {
    VStack(spacing: 8) {
      if let expires = host.pairingExpiresAt {
        Text(host.pairingKey)
          .font(.largeTitle.monospaced().weight(.semibold))
          .textSelection(.enabled)
          .accessibilityIdentifier("remote-mirror-pairing-key")
        HStack(spacing: 4) {
          Text("Expires in")
          Text(expires, style: .timer).monospacedDigit()
        }
        .font(.callout).foregroundStyle(.secondary)
      } else if !host.isRunning && !host.isStarting {
        Text("This Mac is not listening. Start listening to create a pairing code.").foregroundStyle(.secondary)
      } else if !hasRequestedCode || host.isStarting {
        ProgressView("Preparing pairing…")
      } else {
        Text("The code expired. Refresh to create a new one.").foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
  }

  private func copyConnectionDetails() {
    do {
      guard let address = pairingAddress, let port = UInt16(host.port), let expires = host.pairingExpiresAt else {
        throw MirrorPairingPayload.Problem.invalid
      }
      let payload = try MirrorPairingPayload(address: address, port: port, code: host.pairingKey, expires: expires)
      let value = try payload.encoded()
      NSPasteboard.general.clearContents()
      copied = NSPasteboard.general.setString(value, forType: .string)
      copyError = copied ? nil : String(localized: "Unable to copy to the clipboard.")
    } catch {
      copied = false
      copyError = error.localizedDescription
    }
  }
}
