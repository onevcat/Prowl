import SwiftUI

/// The state of a loaded remote folder's host in its sidebar header (docs-ai 084 C1): a
/// host that did not answer shows the last state, and one whose SSH configuration changed
/// waits for a rebind.
struct RemoteHostStatusBadge: View {
  let status: RemoteHostStatus
  let rebind: () -> Void

  var body: some View {
    switch status {
    case .unreachable:
      Image(systemName: "network.slash")
        .foregroundStyle(.secondary)
        .help("The host did not answer. Prowl shows the last state and tries again.")
        .accessibilityLabel("The host did not answer")
    case .connectionFailed(let reason):
      Image(systemName: "network.slash")
        .foregroundStyle(.orange)
        .help(Text(verbatim: reason))
        .accessibilityLabel(Text(verbatim: reason))
    case .needsRebind:
      Button("Rebind Host", systemImage: "exclamationmark.triangle", action: rebind)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.orange)
        .help("The SSH configuration of this host changed. Click to use its new target.")
    }
  }
}
