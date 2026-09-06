import ComposableArchitecture
import Foundation

/// Process-scoped UI switches. Flags never gate CLI/runtime capabilities.
nonisolated struct FeatureFlags: Equatable, Sendable {
  let workflowUI: Bool

  init(environment: [String: String]) {
    workflowUI = environment["PROWL_WORKFLOW_UI"].map { $0 == "1" } ?? true
  }

  func showsSkill(_ id: String) -> Bool {
    workflowUI || id != "prowl-workflow"
  }
}

extension FeatureFlags: DependencyKey {
  static let liveValue = FeatureFlags(environment: ProcessInfo.processInfo.environment)
  // Workflow feature tests exercise the default UI; switch tests inject off.
  static let testValue = FeatureFlags(environment: ["PROWL_WORKFLOW_UI": "1"])
}

extension DependencyValues {
  var featureFlags: FeatureFlags {
    get { self[FeatureFlags.self] }
    set { self[FeatureFlags.self] = newValue }
  }
}
