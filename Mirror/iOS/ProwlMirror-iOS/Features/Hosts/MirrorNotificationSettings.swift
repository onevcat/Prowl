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
      Toggle("Notifications", isOn: Binding(get: { push.isEnabled }, set: setEnabled))
        .accessibilityIdentifier("push-enabled")
      if push.isEnabled {
        Toggle("Show Details", isOn: Binding(get: { push.showsDetails }, set: push.setShowsDetails))
          .accessibilityIdentifier("push-show-details")
        ForEach(store.hosts) { host in
          if let hostID = host.hostID {
            NavigationLink {
              MirrorHostNotificationsView(host: host, hostID: hostID)
            } label: {
              LabeledContent(
                host.displayName,
                value: MirrorPushStatusText.summary(
                  push: push, hostID: hostID, supportsPush: sessions.existing(for: host)?.supportsPush))
            }
          }
        }
      }
    } header: {
      Text("Notifications")
    } footer: {
      if systemDenied, push.isEnabled {
        Text("Notifications are turned off for Prowl Mirror in the Settings app.")
      } else {
        Text(
          """
          When an agent needs you or finishes while you are away from the Mac, the Host sends a \
          notification through the Prowl push service. The content is end-to-end encrypted. \
          Show Details adds the tab and worktree name, also on the lock screen.
          """)
      }
    }
    .task(id: push.isEnabled) {
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      systemDenied = settings.authorizationStatus == .denied
    }
  }

  private func setEnabled(_ enabled: Bool) {
    push.setEnabled(enabled)
    sessions.pushSettingsChanged()
    guard !enabled else { return }
    let hostIDs = store.hosts.compactMap(\.hostID)
    Task {
      for hostID in hostIDs { await push.removeRegistration(for: hostID) }
    }
  }
}

/// The event kinds of one Host, and what the Host last said.
struct MirrorHostNotificationsView: View {
  let host: MirrorHostRecord
  let hostID: UUID
  @Environment(MirrorHostSessions.self) private var sessions
  private let push = MirrorPushCoordinator.shared

  var body: some View {
    Form {
      Section {
        Toggle("An agent needs you", isOn: binding(.blocked))
        Toggle("An agent finished", isOn: binding(.done))
      } footer: {
        Text(
          MirrorPushStatusText.detail(
            push: push, hostID: hostID, supportsPush: sessions.existing(for: host)?.supportsPush))
      }
    }
    .navigationTitle(host.displayName)
    .navigationBarTitleDisplayMode(.inline)
  }

  private func binding(_ kind: MirrorPushKind) -> Binding<Bool> {
    Binding(
      get: { push.kinds(for: hostID).contains(kind) },
      set: { on in
        var kinds = push.kinds(for: hostID)
        if on { kinds.insert(kind) } else { kinds.remove(kind) }
        push.setKinds(kinds, for: hostID)
        sessions.existing(for: host)?.pushSettingsChanged()
        // With nothing left to send, the token goes at once, also while the Host is offline.
        if kinds.isEmpty { Task { await push.removeRegistration(for: hostID) } }
      })
  }
}

enum MirrorPushStatusText {
  /// One word or phrase for the Host row. `supportsPush` is `nil` while the Host is not
  /// connected.
  static func summary(push: MirrorPushCoordinator, hostID: UUID, supportsPush: Bool?) -> String {
    if push.kinds(for: hostID).isEmpty { return String(localized: "Off") }
    if supportsPush == false { return String(localized: "Update Prowl on the Mac") }
    guard let status = push.statuses[hostID] else { return String(localized: "Not connected yet") }
    if !status.pushEnabled || !status.pushAllowedByMac { return String(localized: "Off on the Mac") }
    return status.registered ? String(localized: "On") : String(localized: "Not connected yet")
  }

  static func detail(push: MirrorPushCoordinator, hostID: UUID, supportsPush: Bool?) -> String {
    if push.kinds(for: hostID).isEmpty { return String(localized: "This Host sends no notifications to this phone.") }
    if supportsPush == false {
      return String(localized: "The Prowl version on this Mac cannot send notifications. Update Prowl on the Mac.")
    }
    guard let status = push.statuses[hostID] else {
      return String(localized: "Notifications start the next time this phone connects to the Host.")
    }
    if !status.pushEnabled {
      return String(localized: "Turn on Send Notifications to Paired Devices in Remote Mirror settings on the Mac.")
    }
    if !status.pushAllowedByMac {
      return String(localized: "Notifications to this phone are turned off in Remote Mirror settings on the Mac.")
    }
    return status.registered
      ? String(localized: "The Host notifies this phone while you are away from the Mac.")
      : String(localized: "Notifications start the next time this phone connects to the Host.")
  }
}
