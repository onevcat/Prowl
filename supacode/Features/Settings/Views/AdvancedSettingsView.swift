import ComposableArchitecture
import SwiftUI

struct AdvancedSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

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

          VStack(alignment: .leading, spacing: 8) {
            Toggle(
              "Use anonymous tmux-backed terminals",
              isOn: $store.useAnonymousTmuxBackedTerminals
            )
            .disabled(!store.isTmuxAvailable)
            .help(
              store.isTmuxAvailable
                ? "Run new terminal tabs in hidden tmux sessions"
                : "Install tmux to enable anonymous tmux-backed terminals"
            )
            Text(
              "New terminal tabs run in hidden tmux sessions. Closing a tab detaches it so programs keep running."
            )
              .foregroundStyle(.secondary)
              .font(.callout)
            if !store.isTmuxAvailable {
              Text("tmux is not installed.")
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
}
