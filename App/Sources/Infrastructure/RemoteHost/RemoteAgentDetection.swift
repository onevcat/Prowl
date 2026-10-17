import Foundation

/// The switch for SSH-transparent detection (docs-ai 082, L0). Off until the L0 UX ships;
/// `PROWL_REMOTE_AGENT_DETECTION=1` or the `remoteAgentDetectionEnabled` default turns it
/// on for dogfooding.
nonisolated enum RemoteAgentDetection {
  static let defaultsKey = "remoteAgentDetectionEnabled"
  static let environmentKey = "PROWL_REMOTE_AGENT_DETECTION"

  static var isEnabled: Bool {
    ProcessInfo.processInfo.environment[environmentKey] == "1" || UserDefaults.standard.bool(forKey: defaultsKey)
  }
}
