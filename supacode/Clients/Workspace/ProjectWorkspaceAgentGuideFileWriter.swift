import Foundation

nonisolated enum ProjectWorkspaceAgentGuideWriteError: LocalizedError, Equatable, Sendable {
  case outputOutsideWorkspace(String)
  case missingManagedBlock(String)

  var errorDescription: String? {
    switch self {
    case .outputOutsideWorkspace(let output):
      return "Agent guide output must be a file name inside the workspace root: \(output)"
    case .missingManagedBlock(let output):
      return "\(output) already exists without a Prowl managed block."
    }
  }
}

nonisolated struct ProjectWorkspaceAgentGuideFileWriter {
  static let startMarker = "<!-- prowl:workspace-agent-guide:start -->"
  static let endMarker = "<!-- prowl:workspace-agent-guide:end -->"

  var fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func writer() -> ProjectWorkspaceAgentGuideWriter {
    ProjectWorkspaceAgentGuideWriter { workspace, rootURL in
      try ProjectWorkspaceAgentGuideFileWriter().write(workspace: workspace, rootURL: rootURL)
    }
  }

  func write(workspace: ProjectWorkspace, rootURL: URL) throws {
    let guide = (workspace.agentGuide ?? ProjectWorkspaceAgentGuide()).normalized
    guard guide.enabled else {
      return
    }

    let block = Self.managedBlock(
      for: workspace, guide: guide, rootURL: rootURL, fileManager: fileManager)
    for output in guide.outputs {
      let outputURL = try outputURL(for: output, rootURL: rootURL)
      let nextText: String
      if fileManager.fileExists(atPath: outputURL.path(percentEncoded: false)) {
        let current = try String(contentsOf: outputURL, encoding: .utf8)
        nextText = try Self.replacingManagedBlock(in: current, with: block, output: output)
      } else {
        nextText = "# \(workspace.title)\n\n\(block)"
      }
      try nextText.write(to: outputURL, atomically: true, encoding: .utf8)
    }
  }

  static func managedBlock(
    for workspace: ProjectWorkspace,
    guide: ProjectWorkspaceAgentGuide,
    rootURL: URL,
    fileManager: FileManager = .default
  ) -> String {
    var lines: [String] = [
      startMarker,
      "",
      "## Workspace",
      "",
      "- Title: \(workspace.title)",
      "- Root: \(rootURL.path(percentEncoded: false))",
      "- The workspace root is not a git repository; child repositories live under the paths below.",
    ]
    if !workspace.description.isEmpty {
      lines.append("- Description: \(workspace.description)")
    }
    if !workspace.taskLinks.isEmpty {
      lines.append("")
      lines.append("## Task Links")
      lines.append("")
      for link in workspace.taskLinks {
        lines.append("- \(link)")
      }
    }

    lines.append("")
    lines.append("## Repositories")
    lines.append("")
    for entry in workspace.repositories {
      lines.append("- `\(entry.path)`: \(entry.role ?? entry.name)")
      lines.append("  - Name: \(entry.name)")
      lines.append("  - Source: \(entry.sourceKind.rawValue)")
      if let branch = entry.branchName ?? entry.baseRef {
        lines.append("  - Branch/ref: \(branch)")
      }
      if let notes = entry.agentNotes, !notes.isEmpty {
        lines.append("  - Agent notes: \(notes)")
      }
      if let bootstrap = entry.bootstrap {
        let scripts =
          bootstrap.scriptIDs.isEmpty
          ? bootstrap.scriptPath ?? bootstrap.scriptKind.rawValue
          : bootstrap.scriptIDs.joined(separator: ", ")
        lines.append(
          "  - Bootstrap: \(scripts)"
        )
      }
      if guide.includeChildInstructionFiles {
        let instructionFiles = childInstructionFiles(
          for: entry, rootURL: rootURL, fileManager: fileManager)
        if !instructionFiles.isEmpty {
          lines.append("  - Child instructions:")
          for instructionFile in instructionFiles {
            lines.append("    - `\(instructionFile)`")
          }
        }
      }
    }

    if !guide.extraNotes.isEmpty {
      lines.append("")
      lines.append("## Notes")
      lines.append("")
      lines.append(guide.extraNotes)
    }

    lines.append("")
    lines.append(endMarker)
    lines.append("")
    return lines.joined(separator: "\n")
  }

  static func replacingManagedBlock(
    in text: String,
    with block: String,
    output: String
  ) throws -> String {
    guard let startRange = text.range(of: startMarker),
      let endRange = text.range(of: endMarker, range: startRange.upperBound..<text.endIndex)
    else {
      throw ProjectWorkspaceAgentGuideWriteError.missingManagedBlock(output)
    }

    var result = text
    result.replaceSubrange(
      startRange.lowerBound..<endRange.upperBound, with: block.trimmingCharacters(in: .newlines))
    if !result.hasSuffix("\n") {
      result.append("\n")
    }
    return result
  }

  private func outputURL(for output: String, rootURL: URL) throws -> URL {
    let normalized = ProjectWorkspaceAgentGuide.normalizedOutputs([output])
    guard normalized == [output] else {
      throw ProjectWorkspaceAgentGuideWriteError.outputOutsideWorkspace(output)
    }
    return rootURL.appending(path: output)
  }

  private static func childInstructionFiles(
    for entry: ProjectWorkspace.RepositoryEntry,
    rootURL: URL,
    fileManager: FileManager
  ) -> [String] {
    let candidates = [
      "AGENTS.md",
      "CLAUDE.md",
      ".cursor/rules",
      ".github/copilot-instructions.md",
    ]
    let repositoryURL = entry.resolvedURL(relativeTo: rootURL)
    return candidates.compactMap { candidate in
      let candidateURL = repositoryURL.appending(path: candidate)
      guard fileManager.fileExists(atPath: candidateURL.path(percentEncoded: false)) else {
        return nil
      }
      return "\(entry.path)/\(candidate)"
    }
  }
}
