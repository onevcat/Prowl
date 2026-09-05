import AppKit
import Combine
import ComposableArchitecture
import SwiftUI

struct NotificationsSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var thresholdText = ""

  var body: some View {
    VStack(alignment: .leading) {
      Form {
        Section("Notifications") {
          Toggle(
            "Show bell icon next to worktree",
            isOn: $store.inAppNotificationsEnabled
          )
          .help("Show bell icon next to worktree")
          Picker(selection: $store.notificationSound) {
            Text(NotificationSound.never.displayName).tag(NotificationSound.never)
            Divider()
            ForEach(NotificationSound.systemCases) { sound in
              NotificationSoundLabel(sound: sound).tag(sound)
            }
            Divider()
            NotificationSoundLabel(sound: .supacodeClassic).tag(NotificationSound.supacodeClassic)
          } label: {
            Text("Play notification sound")
            Text(
              "Ignored when system notifications are enabled, as they play sounds"
                + " according to your settings."
            )
          }
          .help("Choose the sound played when a notification is received")
          .disabled(store.systemNotificationsEnabled)
          Toggle(
            "Mute notifications for the active pane",
            isOn: $store.muteNotificationsForActiveSurface
          )
          .help(
            "Skip the banner, sound, and dock bounce when the notification comes from "
              + "the pane you're already looking at."
          )
          Toggle(
            "Move notified worktree to top",
            isOn: $store.moveNotifiedWorktreeToTop
          )
          .help("Bring the worktree to the top when the terminal receives a notification")
          Picker(
            "Bounce dock icon",
            selection: $store.dockBounceMode
          ) {
            ForEach(DockBounceMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .help("Bounce the Prowl app icon in the Dock when a notification is received.")
        }
        Section("System") {
          Toggle(
            "System notifications",
            isOn: $store.systemNotificationsEnabled
          )
          .help("Show macOS system notification banners")
          Toggle(
            "Show notification badge on dock icon",
            isOn: $store.showNotificationDotOnDock
          )
          .help("Show the unread worktree count on the Prowl dock icon.")
          .disabled(!dockBadgeAvailable)
          if let dockBadgeCaption {
            Text(dockBadgeCaption)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
        Section("Command Finished") {
          Toggle(
            "Notify when long-running commands finish",
            isOn: $store.commandFinishedNotificationEnabled
          )
          .help("Show a notification when a command exceeds the duration threshold")
          if store.commandFinishedNotificationEnabled {
            LabeledContent("Duration threshold") {
              HStack(spacing: 4) {
                TextField("", text: $thresholdText)
                  .frame(width: 40)
                  .multilineTextAlignment(.trailing)
                  .onSubmit {
                    store.send(.setCommandFinishedNotificationThreshold(thresholdText))
                  }
                  .onChange(of: store.commandFinishedNotificationThreshold) { _, newValue in
                    thresholdText = String(newValue)
                  }
                Text("seconds")
                  .foregroundStyle(.secondary)
              }
            }
            .help("Minimum command duration in seconds before a notification is shown")
            .onAppear {
              thresholdText = String(store.commandFinishedNotificationThreshold)
            }
          }
        }
      }
      .formStyle(.grouped)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task {
      store.send(.refreshDockBadgeAuthorization)
    }
    // Changing the notification permission or "Badge app icon" switch happens
    // in System Settings, so the moment Prowl regains focus is when to re-read
    // the macOS state and update the toggle live (no restart needed).
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      store.send(.refreshDockBadgeAuthorization)
    }
  }

  private var dockBadgeAvailable: Bool {
    store.dockBadgeAuthorization == .available
  }

  private var dockBadgeCaption: String? {
    switch store.dockBadgeAuthorization {
    case .available:
      return nil
    case .notificationsDenied:
      return "Allow notifications for Prowl in System Settings to show the Dock badge."
    case .badgeDisabled:
      return "Turn on “Badge app icon” for Prowl in System Settings > Notifications."
    }
  }
}

private struct NotificationSoundLabel: View {
  let sound: NotificationSound

  var body: some View {
    if sound == GlobalSettings.default.notificationSound {
      Text("\(sound.displayName) \(Text("Default").foregroundStyle(.secondary))")
    } else {
      Text(sound.displayName)
    }
  }
}
