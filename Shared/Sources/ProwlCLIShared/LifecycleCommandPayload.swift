import Foundation

public struct LifecycleCommandLaunch: Codable, Sendable, Equatable {
  public let profileID: String
  public let profileName: String
  public let agent: String

  enum CodingKeys: String, CodingKey {
    case profileID = "profile_id"
    case profileName = "profile_name"
    case agent
  }

  public init(profileID: String, profileName: String, agent: String) {
    self.profileID = profileID
    self.profileName = profileName
    self.agent = agent
  }
}

nonisolated public enum LifecycleCommandWarningCode: String, Codable, Sendable {
  case managedHookDegraded = "managed_hook_degraded"
}

nonisolated public struct LifecycleCommandWarning: Codable, Sendable, Equatable {
  public let code: LifecycleCommandWarningCode
  public let runtime: String
  public let message: String

  public init(code: LifecycleCommandWarningCode, runtime: String, message: String) {
    self.code = code
    self.runtime = runtime
    self.message = message
  }
}

public struct LifecycleCommandPayload: Codable, Sendable, Equatable {
  public let resource: LifecycleResource
  public let anchor: TabTarget?
  public let direction: CreatePaneDirection?
  public let launch: LifecycleCommandLaunch?
  public let dispatch: DispatchPendingRecord?
  public let warnings: [LifecycleCommandWarning]?
  public let target: TabTarget

  public init(
    resource: LifecycleResource,
    anchor: TabTarget? = nil,
    direction: CreatePaneDirection? = nil,
    launch: LifecycleCommandLaunch? = nil,
    dispatch: DispatchPendingRecord? = nil,
    warnings: [LifecycleCommandWarning]? = nil,
    target: TabTarget
  ) {
    self.resource = resource
    self.anchor = anchor
    self.direction = direction
    self.launch = launch
    self.dispatch = dispatch
    self.warnings = warnings?.isEmpty == true ? nil : warnings
    self.target = target
  }
}
