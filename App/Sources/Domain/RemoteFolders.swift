import Dependencies
import Foundation

/// The switch for remote folders (docs-ai 084 D7): on since C5, when remote tabs, splits
/// and restore all work. `PROWL_REMOTE_FOLDERS=0` turns them off and hides stored ones.
nonisolated enum RemoteFolders {
  static let environmentKey = "PROWL_REMOTE_FOLDERS"

  /// Off for `0`, `false`, `off` or `no` (any case); on otherwise, also when unset.
  static func isEnabled(environment: [String: String]) -> Bool {
    let value = environment[environmentKey]?.trimmingCharacters(in: .whitespaces).lowercased()
    return !["0", "false", "off", "no"].contains(value ?? "")
  }

  /// Read once: the environment does not change while the app runs.
  static let isEnabledInThisProcess = isEnabled(environment: ProcessInfo.processInfo.environment)
}

/// The flag as reducers read it. Tests load remote folders unless they turn it off.
nonisolated enum RemoteFoldersEnabledKey: DependencyKey {
  static let liveValue = RemoteFolders.isEnabledInThisProcess
  static let testValue = true
}
