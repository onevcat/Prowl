import ComposableArchitecture
import Foundation

/// Process-scoped opt-ins for unfinished UI. Flags never gate CLI/runtime capabilities.
nonisolated struct FeatureFlags: Equatable, Sendable {
  let workflowUI: Bool

  init(environment: [String: String]) {
    workflowUI = environment["PROWL_WORKFLOW_UI"] == "1"
  }

  func showsSkill(_ id: String) -> Bool {
    workflowUI || id != "prowl-workflow"
  }
}

extension FeatureFlags: DependencyKey {
  static let liveValue = FeatureFlags(environment: ProcessInfo.processInfo.environment)
  // Existing workflow feature tests exercise the opt-in UI; release-gate tests inject off.
  static let testValue = FeatureFlags(environment: ["PROWL_WORKFLOW_UI": "1"])
}

extension DependencyValues {
  var featureFlags: FeatureFlags {
    get { self[FeatureFlags.self] }
    set { self[FeatureFlags.self] = newValue }
  }
}
