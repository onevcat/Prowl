import AppKit
import ComposableArchitecture
import SwiftUI

struct AdvancedSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var remoteControlTokenStatus: String?

  var body: some View {
    VStack(alignment: .leading) {
      Form {
        Section("Command Line Tool") {
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
              switch store.cliInstallStatus {
              case .installed(let path):
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.green)
                  .accessibilityLabel("Installed")
                Text("Installed at \(path)")
              case .installedDifferentSource(let path):
                Image(systemName: "exclamationmark.triangle.fill")
                  .foregroundStyle(.yellow)
                  .accessibilityLabel("Different version")
                Text("A different version exists at \(path)")
              case .notInstalled:
                Image(systemName: "xmark.circle")
                  .foregroundStyle(.secondary)
                  .accessibilityLabel("Not installed")
                Text("Not installed")
              }
            }
            .font(.callout)

            Text("Install the prowl command to control Prowl from the terminal.")
              .foregroundStyle(.secondary)
              .font(.callout)

            HStack(spacing: 8) {
              switch store.cliInstallStatus {
              case .notInstalled:
                Button("Install") {
                  store.send(.installCLIButtonTapped())
                }
                .help("Install prowl command line tool to /usr/local/bin")
                .buttonStyle(.bordered)
              case .installed:
                Button("Uninstall") {
                  store.send(.uninstallCLIButtonTapped)
                }
                .help("Remove prowl command line tool from /usr/local/bin")
                .buttonStyle(.bordered)
              case .installedDifferentSource:
                Button("Reinstall") {
                  store.send(.installCLIButtonTapped())
                }
                .help("Replace the existing prowl command with the version bundled in this app")
                .buttonStyle(.bordered)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .onAppear {
            store.send(.refreshCLIInstallStatus)
          }
        }

        Section("Advanced") {
          VStack(alignment: .leading) {
            Toggle(
              "Share analytics with Prowl",
              isOn: $store.analyticsEnabled
            )
            .help("Share anonymous usage data with Prowl (requires restart)")
            Text("Anonymous usage data helps improve Prowl.")
              .foregroundStyle(.secondary)
              .font(.callout)
            Text("Requires app restart.")
              .foregroundStyle(.secondary)
              .font(.callout)
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          VStack(alignment: .leading) {
            Toggle(
              "Share crash reports with Prowl",
              isOn: $store.crashReportsEnabled
            )
            .help("Share anonymous crash reports with Prowl (requires restart)")
            Text("Anonymous crash reports help improve stability.")
              .foregroundStyle(.secondary)
              .font(.callout)
            Text("Requires app restart.")
              .foregroundStyle(.secondary)
              .font(.callout)
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          VStack(alignment: .leading, spacing: 8) {
            Toggle(
              "Restore terminal layout on launch (experimental)",
              isOn: $store.restoreTerminalLayoutOnLaunch
            )
            Text("When enabled, Prowl attempts to restore tabs and splits after restart.")
              .foregroundStyle(.secondary)
              .font(.callout)
            Button("Clear saved terminal layout") {
              store.send(.clearTerminalLayoutSnapshotButtonTapped)
            }
            .help("Remove the saved terminal tab and split layout from disk")
            .buttonStyle(.bordered)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        Section("Remote Control (Experimental)") {
          VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable read-only mobile bridge", isOn: $store.remoteControlEnabled)
              .help("Start or stop the authenticated read-only bridge immediately")

            Text(
              "The bridge listens only on 127.0.0.1. Use a private TLS tunnel or overlay to reach it from a phone."
            )
            .foregroundStyle(.secondary)
            .font(.callout)

            Text("It exposes agent status and limited viewport text only; it cannot send input or manage tabs.")
              .foregroundStyle(.secondary)
              .font(.callout)

            HStack(spacing: 8) {
              Button("Copy Access Token") {
                copyRemoteControlToken()
              }
              .help("Copy the Keychain-backed token required by a paired mobile client")
              .buttonStyle(.bordered)
              .disabled(!store.remoteControlEnabled)

              Button("Rotate and Copy Access Token") {
                rotateAndCopyRemoteControlToken()
              }
              .help("Replace the current token and revoke clients using the previous token")
              .buttonStyle(.bordered)
              .disabled(!store.remoteControlEnabled)
            }

            if let remoteControlTokenStatus {
              Text(remoteControlTokenStatus)
                .foregroundStyle(.secondary)
                .font(.callout)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .formStyle(.grouped)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func copyRemoteControlToken() {
    do {
      let token = try RemoteControlAccessTokenStore.shared.loadOrCreate()
      copyToPasteboard(token)
      remoteControlTokenStatus = "Access token copied."
    } catch {
      remoteControlTokenStatus = "Unable to access the Keychain."
    }
  }

  private func rotateAndCopyRemoteControlToken() {
    do {
      let token = try RemoteControlAccessTokenStore.shared.rotate()
      copyToPasteboard(token)
      remoteControlTokenStatus = "New access token copied; previous tokens are revoked."
    } catch {
      remoteControlTokenStatus = "Unable to access the Keychain."
    }
  }

  private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}
