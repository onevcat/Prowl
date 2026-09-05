import Foundation

/// The local-settings identity of one effective workflow definition. Bundle and user
/// definitions are global; repository definitions include the canonical repository root so
/// a preference changed in one repository cannot affect a same-id definition in another.
nonisolated enum WorkflowPreferenceKey {
  static func make(scope: WorkflowRunScope, workflowID: String) -> String {
    switch scope {
    case .bundle:
      return "bundle/\(workflowID)"
    case .user:
      return "user/\(workflowID)"
    case .repo(let repositoryID):
      let rootPath = URL(filePath: repositoryID, directoryHint: .isDirectory)
        .standardizedFileURL
        .path(percentEncoded: false)
      let separator = rootPath.hasSuffix("/") ? "" : "/"
      return "repo:\(rootPath)\(separator)\(workflowID)"
    }
  }

  static func make(
    scope: WorkflowScope,
    workflowID: String,
    repositoryRootPath: String?
  ) -> String? {
    let runScope: WorkflowRunScope
    switch scope {
    case .bundle:
      runScope = .bundle
    case .user:
      runScope = .user
    case .repo:
      guard let repositoryRootPath else { return nil }
      runScope = .repo(repositoryID: repositoryRootPath)
    }
    return make(scope: runScope, workflowID: workflowID)
  }

  static func legacyRepositoryWorkflowID(_ key: String) -> String? {
    let prefix = "repo/"
    guard key.hasPrefix(prefix) else { return nil }
    let workflowID = String(key.dropFirst(prefix.count))
    return workflowID.isEmpty ? nil : workflowID
  }
}

extension UserGlobalSettings {
  /// D1 originally keyed repository enablement and run-setup overrides as `repo/<id>`,
  /// sharing one preference across every repository. Before R2b ships, expand those values
  /// over the repositories Prowl knows and remove the legacy keys. With no repository yet,
  /// retain them so a later repository load can perform the migration without losing state.
  @discardableResult
  mutating func migrateLegacyRepositoryWorkflowPreferences(
    repositoryRootPaths: [String]
  ) -> Bool {
    let roots = Array(Set(repositoryRootPaths)).sorted()
    guard !roots.isEmpty else { return false }

    let legacyDisabled = disabledWorkflowIDs.compactMap(
      WorkflowPreferenceKey.legacyRepositoryWorkflowID)
    let legacyOverrides = workflowBindModeOverrides.compactMap {
      override -> (String, WorkflowBindModeOverride.Mode)? in
      guard let workflowID = WorkflowPreferenceKey.legacyRepositoryWorkflowID(override.workflowKey)
      else {
        return nil
      }
      return (workflowID, override.mode)
    }
    guard !legacyDisabled.isEmpty || !legacyOverrides.isEmpty else { return false }

    var disabled = Set(
      disabledWorkflowIDs.filter { WorkflowPreferenceKey.legacyRepositoryWorkflowID($0) == nil })
    for root in roots {
      let scope = WorkflowRunScope.repo(repositoryID: root)
      for workflowID in legacyDisabled {
        disabled.insert(WorkflowPreferenceKey.make(scope: scope, workflowID: workflowID))
      }
    }
    disabledWorkflowIDs = Self.normalizedWorkflowIDs(Array(disabled))

    var overrides = workflowBindModeOverrides.filter {
      WorkflowPreferenceKey.legacyRepositoryWorkflowID($0.workflowKey) == nil
    }
    var existingKeys = Set(overrides.map(\.workflowKey))
    for root in roots {
      let scope = WorkflowRunScope.repo(repositoryID: root)
      for (workflowID, mode) in legacyOverrides {
        let key = WorkflowPreferenceKey.make(scope: scope, workflowID: workflowID)
        guard existingKeys.insert(key).inserted else { continue }
        overrides.append(WorkflowBindModeOverride(workflowKey: key, mode: mode))
      }
    }
    workflowBindModeOverrides = WorkflowBindModeOverride.normalized(overrides)
    return true
  }
}
