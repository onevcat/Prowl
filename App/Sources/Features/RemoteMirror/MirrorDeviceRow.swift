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
  /// Settings shows the device's push notification state and the Mac's control for it.
  var showsNotifications = false
  let disconnect: (MirrorDisconnectTarget) -> Void

  var body: some View {
    let panes = host.mirroredPanes(for: device.id)
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top) {
        Image(systemName: device.platform?.symbolName ?? MirrorDevicePlatform.unknownSymbolName)
          .foregroundStyle(.secondary)
          .frame(width: 22)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(device.name).lineLimit(1)
          Text(status(mirrorCount: panes.count)).font(.caption).foregroundStyle(.secondary)
          if showsNotifications {
            MirrorDeviceNotificationsRow(host: host, device: device)
          }
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
        // In line with the device name, after the icon column.
        .padding(.leading, 30)
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

/// A device's push notification state, and the Mac user's control for it (docs-ai 095).
private struct MirrorDeviceNotificationsRow: View {
  let host: MirrorHost
  let device: MirrorPairedDevice

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      controls
      if let last = host.lastPushes[device.id] {
        Text(last.summary).font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("remote-mirror-device-last-push-\(device.id)")
      }
    }
  }

  private var controls: some View {
    HStack(spacing: 6) {
      Text(state).font(.caption).foregroundStyle(.secondary)
      // The Mac's choice persists without a registration, so its control shows either way.
      if !device.isPushAllowedByMac {
        Button("Turn On") { host.setPushAllowed(true, for: device.id) }
          .help("Allow notifications to this device again")
          .accessibilityIdentifier("remote-mirror-device-notifications-on-\(device.id)")
      } else if device.push != nil {
        Button("Turn Off") { host.setPushAllowed(false, for: device.id) }
          .help("Stop notifications to this device; the device cannot turn them on again")
          .accessibilityIdentifier("remote-mirror-device-notifications-off-\(device.id)")
      }
    }
    .buttonStyle(.link)
    .font(.caption)
  }

  private var state: String {
    guard device.isPushAllowedByMac else { return String(localized: "Notifications off for this device") }
    guard device.push != nil else {
      return String(localized: "Notifications not set up · turn them on in Prowl Mirror on this device")
    }
    return String(localized: "Notifications on")
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

extension MirrorPushDelivery {
  /// The last push in words, so that a missing notification can be traced (docs-ai 095 M4).
  var summary: String {
    let time = date.formatted(date: .omitted, time: .shortened)
    switch result {
    case .accepted:
      return String(localized: "Last notification sent at \(time)")
    case .tokenGone:
      return String(
        localized: "Last notification at \(time) not delivered: the device renews its registration when it connects")
    case .failed(let reason):
      return String(localized: "Last notification at \(time) failed (\(reason))")
    }
  }
}
