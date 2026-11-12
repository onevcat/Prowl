import ComposableArchitecture
import SwiftUI

struct MirrorHostButton: View {
  @Environment(RemoteMirrorStore.self) private var mirrors
  @Environment(ToolbarPopoverCoordinator.self) private var popovers
  @State private var isPairing = false

  private var status: String {
    if !mirrors.host.isRunning { return String(localized: "Off") }
    if mirrors.host.subscriberCount == 0 { return String(localized: "Listening") }
    return String(localized: "Mirroring")
  }

  private var tint: Color {
    guard mirrors.host.isRunning else { return .secondary }
    return mirrors.host.subscriberCount == 0 ? .blue.opacity(0.65) : .green.opacity(0.65)
  }

  var body: some View {
    if mirrors.isEnabled {
      let isPresented = popovers.presented == .mirror
      Button {
        popovers.toggle(.mirror)
      } label: {
        Image(systemName: "network").foregroundStyle(tint)
      }
      .help("Remote Mirror — \(status). Hover to preview or click to keep open.")
      .accessibilityLabel("Remote Mirror — \(status)")
      .accessibilityIdentifier("remote-mirror-host-button")
      .onHover { if !isPairing { popovers.hoverButton(.mirror, hovering: $0) } }
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
          MirrorHostPanel(
            host: mirrors.host,
            interact: { popovers.pin(.mirror) },
            pair: presentPairing,
            openSettings: {
              popovers.dismiss(.mirror)
              mirrors.openSettings?()
            }
          )
          .fixedSize(horizontal: false, vertical: true)
        }
        .onHover { popovers.hoverPopover(.mirror, hovering: $0) }
      }
      .background {
        Color.clear
          .sheet(isPresented: $isPairing) {
            MirrorPairingView(host: mirrors.host) { isPairing = false }
          }
      }
      .onDisappear {
        popovers.dismiss(.mirror)
      }
    }
  }

  private func presentPairing() {
    popovers.dismiss(.mirror)
    isPairing = true
  }
}

private struct MirrorPopover<Content: View>: View {
  @ViewBuilder let content: () -> Content
  @State private var contentHeight: CGFloat = 200

  var body: some View {
    ScrollView {
      content()
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          contentHeight = $0
        }
    }
    .frame(width: 340, height: min(contentHeight, max(160, (NSScreen.main?.visibleFrame.height ?? 840) - 180)))
    .transaction { $0.animation = nil }
  }
}

/// The toolbar panel (docs-ai 091): the frequent actions for connections to this Mac. Settings
/// holds the configuration and the full device list.
private struct MirrorHostPanel: View {
  let host: MirrorHost
  let interact: () -> Void
  let pair: () -> Void
  let openSettings: () -> Void
  @State private var mirrorToDisconnect: MirrorDisconnectTarget?

  private var onlineDevices: [MirrorPairedDevice] { host.devices.filter { host.isOnline($0.id) } }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("Remote Mirror").font(.headline)
        Spacer()
        Text(MirrorHostStatus.text(for: host)).font(.subheadline).foregroundStyle(.secondary)
      }
      HStack {
        if host.isRunning || host.isStarting {
          Button("Add a Device…", action: pair)
            .help("Show a single-use pairing code with a 60-second expiry")
            .disabled(host.isStarting)
          Spacer()
          Button("Stop Listening", role: .destructive) {
            interact()
            host.stop()
          }
          .help("Disconnect all devices and stop listening; local terminals keep running")
        } else {
          Text("Paired devices cannot connect to this Mac.").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Start Listening") {
            interact()
            host.start()
          }
          .buttonStyle(.borderedProminent)
          .help("Let paired devices connect to this Mac")
        }
      }
      if let error = host.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      if host.isRunning {
        Divider()
        if onlineDevices.isEmpty {
          Text("No device is connected.").font(.caption).foregroundStyle(.secondary)
        } else {
          ForEach(onlineDevices) { device in
            MirrorDeviceRow(host: host, device: device) {
              interact()
              mirrorToDisconnect = $0
            }
          }
        }
      }
      Divider()
      Button("Remote Mirror Settings…", action: openSettings)
        .buttonStyle(.link)
        .help("Open Settings to manage paired devices, the listener, and connections to another Mac")
        .accessibilityIdentifier("remote-mirror-open-settings")
    }
    .padding(16)
    .frame(width: 340)
    .accessibilityIdentifier("remote-mirror-host-panel")
    .mirrorDisconnectAlert($mirrorToDisconnect, host: host)
  }
}
