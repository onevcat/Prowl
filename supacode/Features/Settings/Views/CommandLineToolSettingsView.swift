import ComposableArchitecture
import ProwlCLIShared
import SwiftUI

/// Settings → Agents → CLI & Skills: install/status for the bundled `prowl`
/// CLI, the socket it reaches the app through, and the bundled agent skills
/// (`AgentSkillsFeature`). Installation behavior stays in the reducers; this view
/// only presents it.
struct CommandLineToolSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Form {
      Section("Installation") {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 6) {
            switch store.cliInstallStatus {
            case .installed(let path):
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Installed")
              Text("Installed at \(path)")
            case .installedDifferentSource(let path, _):
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityLabel("Different version")
              Text("A different version exists at \(path)")
            case .broken(let path, _):
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityLabel("Broken link")
              Text("A broken link exists at \(path)")
            case .notInstalled:
              Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not installed")
              Text("Not installed")
            }
          }
          .font(.callout)

          Text("Install the prowl command to let terminals and coding agents control Prowl.")
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
            case .broken:
              Button("Repair") {
                store.send(.installCLIButtonTapped())
              }
              .help("Replace the broken prowl link with the version bundled in this app")
              .buttonStyle(.bordered)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
          store.send(.refreshCLIInstallStatus)
          store.send(.refreshCLIServiceStatus)
        }
      }

      Section("Connection") {
        LabeledContent("Socket") {
          Text(socketPath)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        LabeledContent("Status") {
          HStack(spacing: 6) {
            connectionStatusIcon
            Text(connectionStatusText)
          }
          .font(.callout)
        }

        if let failure = store.cliServiceStatus.failureDescription {
          Text(failure)
            .foregroundStyle(.secondary)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }

        Text(
          "prowl reaches the running app through this local Unix socket. "
            + "Set PROWL_CLI_SOCKET for both Prowl and prowl to use a different path."
        )
        .foregroundStyle(.secondary)
        .font(.callout)
      }

      if let agentSkillsStore = store.scope(state: \.agentSkills, action: \.agentSkills) {
        AgentSkillsSectionView(store: agentSkillsStore)
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// The path the server actually bound (or failed to bind), falling back to the default
  /// before the first status arrives.
  private var socketPath: String {
    switch store.cliServiceStatus {
    case .listening(let path), .failed(_, let path): path
    case .stopped: ProwlSocket.defaultPath
    }
  }

  @ViewBuilder
  private var connectionStatusIcon: some View {
    switch store.cliServiceStatus {
    case .listening:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityLabel("Listening")
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.yellow)
        .accessibilityLabel("Not listening")
    case .stopped:
      Image(systemName: "xmark.circle")
        .foregroundStyle(.secondary)
        .accessibilityLabel("Not running")
    }
  }

  private var connectionStatusText: String {
    switch store.cliServiceStatus {
    case .listening: "Listening"
    case .failed: "Not listening"
    case .stopped: "Not running"
    }
  }
}
