import SwiftUI

/// One mirror that this Mac can disconnect without revoking the device.
struct MirrorDisconnectTarget {
  let subscriptionID: UUID
  let paneTitle: String
  let deviceName: String
}

/// A paired device and the panes that it mirrors now. `revoke` is nil where the row only reports.
struct MirrorDeviceRow: View {
  let host: MirrorHost
  let device: MirrorPairedDevice
  var revoke: (() -> Void)?
  let disconnect: (MirrorDisconnectTarget) -> Void

  var body: some View {
    let panes = host.mirroredPanes(for: device.id)
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(device.name).lineLimit(1)
          Text(status(mirrorCount: panes.count)).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if let revoke {
          Button("Revoke", role: .destructive, action: revoke)
            .help("Disconnect this device and require it to pair again")
        }
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
            disconnect(
              MirrorDisconnectTarget(
                subscriptionID: subscriptionID, paneTitle: pane.title, deviceName: device.name))
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

  private func status(mirrorCount: Int) -> String {
    if host.isOnline(device.id) {
      return String(localized: "Connected · \(MirrorHostStatus.mirrors(mirrorCount))")
    }
    guard let seen = device.lastSeen else { return String(localized: "Paired · never connected") }
    return String(localized: "Last seen \(seen.formatted(.relative(presentation: .named)))")
  }
}

/// The listener state in words, shared by the toolbar panel and Settings.
@MainActor
enum MirrorHostStatus {
  static func text(for host: MirrorHost) -> String {
    if host.isStarting { return String(localized: "Starting…") }
    guard host.isRunning else { return String(localized: "Off") }
    return String(localized: "Listening · \(mirrors(host.subscriberCount))")
  }

  static func mirrors(_ count: Int) -> String {
    count == 1 ? String(localized: "1 mirror") : String(localized: "\(count) mirrors")
  }
}

extension View {
  /// Confirms the disconnect of one mirror. The device stays paired.
  func mirrorDisconnectAlert(_ target: Binding<MirrorDisconnectTarget?>, host: MirrorHost) -> some View {
    alert(
      "Disconnect Mirror?",
      isPresented: Binding(get: { target.wrappedValue != nil }, set: { if !$0 { target.wrappedValue = nil } }),
      presenting: target.wrappedValue
    ) { target in
      Button("Disconnect", role: .destructive) { host.disconnect(subscriptionID: target.subscriptionID) }
      Button("Cancel", role: .cancel) {}
    } message: { target in
      Text(
        """
        Disconnect \(target.deviceName) from \(target.paneTitle)? \
        The terminal keeps running. The device stays paired and can reconnect.
        """)
    }
  }
}
