import Dependencies
import Foundation

/// The switch for remote folders (docs-ai 084 D7). They stay hidden until remote tabs,
/// splits and restore all work; C5 turns them on.
nonisolated enum RemoteFolders {
  static let environmentKey = "PROWL_REMOTE_FOLDERS"

  static func isEnabled(environment: [String: String]) -> Bool {
    environment[environmentKey] == "1"
  }

  /// Read once: the environment does not change while the app runs.
  static let isEnabledInThisProcess = isEnabled(environment: ProcessInfo.processInfo.environment)
}

/// The flag as reducers read it. Tests load remote folders unless they turn it off.
nonisolated enum RemoteFoldersEnabledKey: DependencyKey {
  static let liveValue = RemoteFolders.isEnabledInThisProcess
  static let testValue = true
}
