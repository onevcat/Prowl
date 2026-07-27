import ComposableArchitecture
import Foundation

/// Where account directories live. Injected so tests never create logins,
/// symlinks or config directories inside the user's real `~/.prowl`.
nonisolated enum AgentAccountsDirectoryKey: DependencyKey {
  static var liveValue: URL { SupacodePaths.agentAccountsDirectory }
  static var previewValue: URL { SupacodePaths.agentAccountsDirectory }
  static var testValue: URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "prowl-test-accounts")
  }
}

extension DependencyValues {
  nonisolated var agentAccountsDirectory: URL {
    get { self[AgentAccountsDirectoryKey.self] }
    set { self[AgentAccountsDirectoryKey.self] = newValue }
  }
}
