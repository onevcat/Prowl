import SwiftUI

struct AgentAccountStatusRow: View {
  let account: String
  let status: AgentAccountStatus?
  let isChecking: Bool
  let authenticate: (AgentAccountCLI, AgentAccountAuthAction) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(account)
        .font(.body.weight(.medium))
      cliRow(.claude, state: status?.claude)
      cliRow(.codex, state: status?.codex)
      if let diverged = status?.divergedConfig, !diverged.isEmpty {
        Label(
          "Own copy of \(diverged.joined(separator: ", ")) — changes to your configuration "
            + "no longer reach this account.",
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.secondary)
        .font(.callout)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func cliRow(_ cli: AgentAccountCLI, state: AgentAccountStatus.LoginState?) -> some View {
    HStack(spacing: 8) {
      Text(cli.displayName)
        .foregroundStyle(.secondary)
        .frame(width: 100, alignment: .leading)
      Text(description(for: state))
        .foregroundStyle(state == nil ? .secondary : .primary)
        .textSelection(.enabled)
      Spacer(minLength: 8)
      switch state {
      case .signedIn:
        Button("Sign Out") { authenticate(cli, .signOut) }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .help("Open a terminal tab that signs \(account) out of \(cli.displayName)")
      case .signedOut:
        Button("Sign In") { authenticate(cli, .signIn) }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .help("Open a terminal tab that signs \(account) in to \(cli.displayName)")
      case .unavailable, nil:
        EmptyView()
      }
    }
    .font(.callout)
  }

  private func description(for state: AgentAccountStatus.LoginState?) -> String {
    switch state {
    case .signedIn(let identity): identity
    case .signedOut: "Not signed in"
    case .unavailable: "Command line tool not found"
    case nil: isChecking ? "Checking…" : "Not checked"
    }
  }
}
