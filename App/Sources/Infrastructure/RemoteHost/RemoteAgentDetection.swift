import Foundation

/// The switch for SSH-transparent detection (docs-ai 082, L0). On by default since the L0 UX
/// shipped; `PROWL_REMOTE_AGENT_DETECTION=0` or a `false` `remoteAgentDetectionEnabled`
/// default turns it off.
nonisolated enum RemoteAgentDetection {
  static let defaultsKey = "remoteAgentDetectionEnabled"
  static let environmentKey = "PROWL_REMOTE_AGENT_DETECTION"

  static var isEnabled: Bool {
    isEnabled(environment: ProcessInfo.processInfo.environment, defaults: .standard)
  }

  static func isEnabled(environment: [String: String], defaults: UserDefaults) -> Bool {
    if let value = environment[environmentKey] { return value != "0" }
    return defaults.object(forKey: defaultsKey) as? Bool ?? true
  }
}
