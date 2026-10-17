import Foundation

/// How the app shows a remote agent's host and connection health (docs-ai 082, L0 item 10).
/// Health is separate from the agent's state: a stale observation keeps the last state and
/// says when the host last confirmed it.
nonisolated enum RemoteAgentHealth: Equatable, Sendable {
  /// The host confirms the agent and evidence decides its state.
  case live
  /// The host confirms the agent, but no evidence decides its state.
  case unknownState
  /// The host last confirmed the agent at this time.
  case lastSeen(Date)
  /// The host never confirmed the agent, or cannot be read.
  case unavailable

  init(_ remote: RemoteAgentContext) {
    if remote.isStale {
      self = remote.lastConfirmedAt.map(Self.lastSeen) ?? .unavailable
    } else {
      self = remote.isStateKnown ? .live : .unknownState
    }
  }
}

nonisolated enum RemoteAgentPresentation {
  /// `user@hostname`, or a generic label while the connection is not resolved.
  static func hostLabel(for remote: RemoteAgentContext) -> String {
    remote.hostLabel ?? String(localized: "Remote host")
  }

  /// Why the observation rests on what it does, for the row's tooltip.
  static func explanation(for remote: RemoteAgentContext) -> String {
    let host = hostLabel(for: remote)
    let correlation = correlationExplanation(remote.correlation, host: host)
    guard remote.isUnprobed else { return correlation }
    let unprobed = String(
      localized: "The status comes only from the agent's own terminal reports, so it can be out of date.")
    return "\(correlation) \(unprobed)"
  }

  static func correlationExplanation(_ correlation: RemotePaneCorrelation, host: String) -> String {
    switch correlation {
    case .pending:
      return String(localized: "Prowl is connecting to \(host).")
    case .correlated:
      return String(localized: "Prowl reads this agent from \(host) over a separate SSH connection.")
    case .ambiguous:
      return String(localized: "More than one session on \(host) carries this pane's ID.")
    case .unmapped:
      return String(
        localized: """
          \(host) has no session for this pane. The ssh client does not send LC_PROWL_PANE \
          (SendEnv), or the server does not accept it (AcceptEnv).
          """)
    case .probeUnavailable(let failure):
      return String(localized: "Prowl cannot read \(host): \(failureReason(failure)).")
    case .unsupported(let reason):
      return String(localized: "Prowl does not read hosts for this ssh command: \(reason).")
    }
  }

  /// Why Prowl does not read a pane's agents, with what still works.
  static func paneIssueExplanation(_ issue: RemotePaneCorrelation, host: String) -> String {
    let reason = correlationExplanation(issue, host: host)
    let fallback = String(
      localized: "Agents in this pane are detected only when they report their status themselves (OSC 7501).")
    return "\(reason) \(fallback)"
  }

  /// What the pane's own accessibility element says about its `ssh`: the badge is not in the
  /// terminal's accessibility tree, so the pane carries the same information.
  static func paneAccessibility(_ indicator: RemotePaneIndicator?, now: Date) -> (label: String?, help: String?) {
    switch indicator {
    case .connected(let host, _, nil):
      return (String(localized: "connected to \(host)"), nil)
    case .connected(let host, _, let issue?):
      return (String(localized: "connected to \(host)"), paneIssueExplanation(issue, host: host))
    case .ended(let host, _) where indicator?.showsEndedMarker(now: now) == true:
      return (String(localized: "disconnected from \(host)"), nil)
    case .ended, nil:
      return (nil, nil)
    }
  }

  static func failureReason(_ failure: RemoteProbeFailure?) -> String {
    switch failure {
    case .authentication:
      return String(localized: "the key was refused or needs a prompt")
    case .hostKey:
      return String(localized: "the host key is unknown or changed")
    case .unresolvableHost:
      return String(localized: "the host name does not resolve")
    case .unreachable:
      return String(localized: "the host is not reachable")
    case .launch:
      return String(localized: "ssh could not start")
    case .exit(_, let line):
      return line.isEmpty ? String(localized: "ssh failed") : line
    case .unrecognizedOutput:
      return String(localized: "the remote shell printed unexpected output")
    case nil:
      return String(localized: "the connection failed or timed out")
    }
  }
}
