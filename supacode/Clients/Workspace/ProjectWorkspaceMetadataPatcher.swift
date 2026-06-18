import Foundation

nonisolated enum ProjectWorkspaceMetadataPatchError: LocalizedError, Equatable, Sendable {
  case metadataNotFound(String)
  case invalidMetadata
  case notEnoughRepositories

  var errorDescription: String? {
    switch self {
    case .metadataNotFound(let path):
      return "Workspace metadata not found at \(path)."
    case .invalidMetadata:
      return "Workspace metadata is not a JSON object."
    case .notEnoughRepositories:
      return "A workspace needs at least two repositories."
    }
  }
}

nonisolated struct ProjectWorkspaceMetadataPatcher: Sendable {
  nonisolated(unsafe) var fileManager: FileManager
  var now: @Sendable () -> Date

  init(
    fileManager: FileManager = .default,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.fileManager = fileManager
    self.now = now
  }

  func save(_ workspace: ProjectWorkspace, rootURL: URL) throws -> ProjectWorkspace {
    guard workspace.repositories.count >= 2 else {
      throw ProjectWorkspaceMetadataPatchError.notEnoughRepositories
    }

    let metadataURL = ProjectWorkspace.metadataURL(for: rootURL)
    let metadataPath = metadataURL.path(percentEncoded: false)
    guard fileManager.fileExists(atPath: metadataPath) else {
      throw ProjectWorkspaceMetadataPatchError.metadataNotFound(metadataPath)
    }

    let data = try Data(contentsOf: metadataURL)
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ProjectWorkspaceMetadataPatchError.invalidMetadata
    }

    let updatedWorkspace = updated(workspace, rootURL: rootURL)
    object["schema_version"] = updatedWorkspace.schemaVersion
    object["id"] = updatedWorkspace.id
    object["title"] = updatedWorkspace.title
    object["description"] = updatedWorkspace.description
    object["task_links"] = updatedWorkspace.taskLinks
    object["agent_guide"] = agentGuideObject(updatedWorkspace.agentGuide)
    object["updated_at"] = ISO8601DateFormatter().string(from: updatedWorkspace.updatedAt ?? now())
    if let createdAt = updatedWorkspace.createdAt {
      object["created_at"] = ISO8601DateFormatter().string(from: createdAt)
    }
    object["repositories"] = try patchedRepositories(
      existing: object["repositories"] as? [[String: Any]] ?? [],
      updated: updatedWorkspace.repositories
    )

    let output = try JSONSerialization.data(
      withJSONObject: object,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try output.write(to: metadataURL, options: .atomic)
    return ProjectWorkspace.load(from: rootURL) ?? updatedWorkspace
  }

  private func updated(_ workspace: ProjectWorkspace, rootURL: URL) -> ProjectWorkspace {
    var copy = workspace
    copy.updatedAt = now()
    return copy.normalized(relativeTo: rootURL)
  }

  private func patchedRepositories(
    existing: [[String: Any]],
    updated: [ProjectWorkspace.RepositoryEntry]
  ) throws -> [[String: Any]] {
    var existingByID: [String: [String: Any]] = [:]
    for entry in existing {
      guard let id = entry["id"] as? String, !id.isEmpty else {
        continue
      }
      existingByID[id] = entry
    }

    return updated.map { updatedEntry in
      let object = existingByID[updatedEntry.id] ?? [:]
      return patchedRepository(object, with: updatedEntry)
    }
  }

  private func patchedRepository(
    _ existing: [String: Any],
    with updatedEntry: ProjectWorkspace.RepositoryEntry
  ) -> [String: Any] {
    var object = existing
    object["id"] = updatedEntry.id
    object["name"] = updatedEntry.name
    object["role"] = updatedEntry.role
    object["agent_notes"] = updatedEntry.agentNotes
    object["path"] = updatedEntry.path
    object["source_kind"] = updatedEntry.sourceKind.rawValue
    object["source_location"] = updatedEntry.sourceLocation
    object["branch_name"] = updatedEntry.branchName
    object["base_ref"] = updatedEntry.baseRef
    object["bootstrap"] = bootstrapObject(updatedEntry.bootstrap)
    return object
  }

  private func agentGuideObject(_ guide: ProjectWorkspaceAgentGuide?) -> [String: Any]? {
    guard let guide else {
      return nil
    }
    let normalized = guide.normalized
    return [
      "enabled": normalized.enabled,
      "outputs": normalized.outputs,
      "include_child_instruction_files": normalized.includeChildInstructionFiles,
      "extra_notes": normalized.extraNotes,
    ]
  }

  private func bootstrapObject(_ bootstrap: ProjectWorkspaceRepositoryBootstrap?) -> [String: Any]? {
    guard let bootstrap else {
      return nil
    }
    var object: [String: Any] = [
      "script_kind": bootstrap.scriptKind.rawValue,
      "run_on": bootstrap.runOn.map(\.rawValue).sorted(),
      "required": bootstrap.required,
    ]
    object["script_ids"] = bootstrap.scriptIDs.isEmpty ? nil : bootstrap.scriptIDs
    object["script_path"] = bootstrap.scriptPath
    return object
  }
}
