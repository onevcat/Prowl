import Foundation

/// What a pane shows about its foreground `ssh` (docs-ai 082, L0 item 10).
nonisolated enum RemotePaneIndicator: Hashable, Sendable {
  /// The pane's foreground `ssh` reaches this host (`user@hostname`).
  case connected(String)
  /// That `ssh` exited, so the pane is back in its local shell.
  case ended(String)

  var connectedHost: String? {
    guard case .connected(let host) = self else { return nil }
    return host
  }
}
