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

        Section("Agent Accounts") {
          VStack(alignment: .leading, spacing: 8) {
            TextField("Default account", text: $store.defaultAgentAccount, prompt: Text("System login"))
              .help("Agent account used when a repository has no override and no matching rule")
            AgentAccountNameWarning(name: store.defaultAgentAccount)
            Text(
              "Each account keeps its own Claude Code and Codex login in ~/.prowl/accounts. "
                + "Leave empty to use the system-wide logins."
            )
            .foregroundStyle(.secondary)
            .font(.callout)
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          if !store.agentAccountNames.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Text("Logins")
                Spacer()
                Button("Refresh") {
                  store.send(.refreshAgentAccountStatuses)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(store.isLoadingAgentAccountStatuses)
                .help("Ask both CLIs which account they are signed in as")
              }
              ForEach(store.agentAccountNames, id: \.self) { account in
                AgentAccountStatusRow(
                  account: account,
                  status: store.agentAccountStatuses[account]
                ) { cli, action in
                  store.send(.agentAccountAuthButtonTapped(account: account, cli: cli, action: action))
                }
              }
              Text("Sign In and Sign Out open a terminal tab in the current repository and run the command there.")
                .foregroundStyle(.secondary)
                .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
              store.send(.refreshAgentAccountStatuses)
            }
          }

          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
              Text("Path")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
              Text("Account")
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
              // Keeps the header aligned with the rows' remove button.
              Color.clear.frame(width: 20)
            }
            .font(.callout)
            ForEach($store.agentAccountRules) { $rule in
              AgentAccountRuleRow(rule: $rule) {
                store.send(.removeAgentAccountRuleButtonTapped(id: rule.id))
              }
            }
            Button("Add Rule") {
              store.send(.addAgentAccountRuleButtonTapped)
            }
            .buttonStyle(.bordered)
            .help("Map a directory to an agent account")
            Text("Repositories under a listed path use that account. The longest matching path wins.")
              .foregroundStyle(.secondary)
              .font(.callout)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
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
      }
      .formStyle(.grouped)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
