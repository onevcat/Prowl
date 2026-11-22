import SwiftUI
import UserNotifications

/// The Notifications section of the Host list (docs-ai 095 P3e): the switch for this phone,
/// and one row per paired Host.
struct MirrorNotificationsSection: View {
  let store: MirrorHostStore
  @Environment(MirrorHostSessions.self) private var sessions
  private let push = MirrorPushCoordinator.shared
  @State private var systemDenied = false

  var body: some View {
    Section {
      Toggle("Notifications", isOn: Binding(get: { push.settings.isEnabled }, set: setEnabled))
        .accessibilityIdentifier("push-enabled")
      if push.settings.isEnabled {
        Toggle(isOn: Binding(get: { push.settings.showsDetails }, set: push.settings.setShowsDetails)) {
          Text("Show Details")
          Text("Show the tab name and what the agent asks or replies, also on the lock screen.")
        }
        .accessibilityIdentifier("push-show-details")
        // One row per Mac: its addresses share the kinds and the token.
        ForEach(macs, id: \.hostID) { mac in
          NavigationLink {
            MirrorHostNotificationsView(name: mac.host.displayName, hostID: mac.hostID)
          } label: {
            LabeledContent(
              mac.host.displayName,
              value: MirrorPushStatusText.summary(
                push: push, hostID: mac.hostID, supportsPush: sessions.supportsPush(hostID: mac.hostID)))
          }
        }
      }
    } header: {
      Text("Notifications")
    } footer: {
      if systemDenied, push.settings.isEnabled {
        Text("Notifications are turned off for Prowl Mirror in the Settings app.")
      } else {
        Text("Sent when an agent needs you or finishes while you are away from the Mac. End-to-end encrypted.")
      }
    }
    .task(id: push.settings.isEnabled) {
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      systemDenied = settings.authorizationStatus == .denied
    }
  }

  private var macs: [(hostID: UUID, host: MirrorHostRecord)] {
    MirrorNotificationsSection.macs(
      among: store.hosts, selectedID: store.selectedHost?.id,
      isConnected: { sessions.existing(for: $0)?.status == .ready })
  }

  /// Each paired Mac once, in list order, named after the entry that a tap would open.
  static func macs(
    among hosts: [MirrorHostRecord], selectedID: UUID?, isConnected: (MirrorHostRecord) -> Bool
  ) -> [(hostID: UUID, host: MirrorHostRecord)] {
    var seen = Set<UUID>()
    return hosts.compactMap(\.hostID).filter { seen.insert($0).inserted }.compactMap { hostID in
      MirrorNotificationRouter.entry(for: hostID, among: hosts, selectedID: selectedID, isConnected: isConnected)
        .map { (hostID: hostID, host: $0) }
    }
  }

  private func setEnabled(_ enabled: Bool) {
    sessions.setNotificationsEnabled(enabled)
  }
}

/// The event kinds of one Host, and what the Host last said.
struct MirrorHostNotificationsView: View {
  let name: String
  let hostID: UUID
  @Environment(MirrorHostSessions.self) private var sessions
  private let push = MirrorPushCoordinator.shared

  var body: some View {
    Form {
      Section {
        Toggle("An agent needs you", isOn: binding(.blocked))
        Toggle("An agent finished", isOn: binding(.done))
      } footer: {
        Text(MirrorPushStatusText.detail(push: push, hostID: hostID, supportsPush: sessions.supportsPush(hostID: hostID)))
      }
    }
    .navigationTitle(name)
    .navigationBarTitleDisplayMode(.inline)
  }

  private func binding(_ kind: MirrorPushKind) -> Binding<Bool> {
    Binding(
      get: { push.settings.kinds(for: hostID).contains(kind) },
      set: { on in
        var kinds = push.settings.kinds(for: hostID)
        if on { kinds.insert(kind) } else { kinds.remove(kind) }
        sessions.setNotificationKinds(kinds, for: hostID)
      })
  }
}

enum MirrorPushStatusText {
  /// One word or phrase for the Host row. `supportsPush` is `nil` while the Host is not
  /// connected.
  static func summary(push: MirrorPushCoordinator, hostID: UUID, supportsPush: Bool?) -> String {
    if push.settings.kinds(for: hostID).isEmpty { return String(localized: "Off") }
    if supportsPush == false { return String(localized: "Update Prowl on the Mac") }
    guard let status = push.statuses[hostID] else { return String(localized: "Not connected yet") }
    if !status.pushEnabled || !status.pushAllowedByMac { return String(localized: "Off on the Mac") }
    return status.registered ? String(localized: "On") : String(localized: "Not connected yet")
  }

  static func detail(push: MirrorPushCoordinator, hostID: UUID, supportsPush: Bool?) -> String {
    if push.settings.kinds(for: hostID).isEmpty { return String(localized: "No notifications from this Mac.") }
    if supportsPush == false {
      return String(localized: "Update Prowl on this Mac to get notifications.")
    }
    guard let status = push.statuses[hostID] else {
      return String(localized: "Notifications start the next time you connect to this Mac.")
    }
    if !status.pushEnabled {
      return String(localized: "On the Mac, turn on “Send notifications to paired devices” in Remote Mirror settings.")
    }
    if !status.pushAllowedByMac {
      return String(localized: "Turned off for this phone in Remote Mirror settings on the Mac.")
    }
    return status.registered
      ? String(localized: "You get notifications while you are away from this Mac.")
      : String(localized: "Notifications start the next time you connect to this Mac.")
  }
}
