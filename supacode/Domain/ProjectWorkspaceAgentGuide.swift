import Foundation

nonisolated struct ProjectWorkspaceAgentGuide: Codable, Equatable, Hashable, Sendable {
  static let defaultOutput = "AGENTS.md"

  var enabled: Bool
  var outputs: [String]
  var includeChildInstructionFiles: Bool
  var extraNotes: String

  enum CodingKeys: String, CodingKey {
    case enabled
    case outputs
    case includeChildInstructionFiles = "include_child_instruction_files"
    case extraNotes = "extra_notes"
  }

  init(
    enabled: Bool = false,
    outputs: [String] = [Self.defaultOutput],
    includeChildInstructionFiles: Bool = true,
    extraNotes: String = ""
  ) {
    self.enabled = enabled
    self.outputs = outputs
    self.includeChildInstructionFiles = includeChildInstructionFiles
    self.extraNotes = extraNotes
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    outputs =
      try container.decodeIfPresent([String].self, forKey: .outputs)
      ?? [Self.defaultOutput]
    includeChildInstructionFiles =
      try container.decodeIfPresent(Bool.self, forKey: .includeChildInstructionFiles) ?? true
    extraNotes = try container.decodeIfPresent(String.self, forKey: .extraNotes) ?? ""
  }

  var normalized: ProjectWorkspaceAgentGuide {
    let normalizedOutputs = Self.normalizedOutputs(outputs)
    return ProjectWorkspaceAgentGuide(
      enabled: enabled,
      outputs: normalizedOutputs.isEmpty ? [Self.defaultOutput] : normalizedOutputs,
      includeChildInstructionFiles: includeChildInstructionFiles,
      extraNotes: extraNotes.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  static func normalizedOutputs(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value -> String? in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\\"),
        trimmed != ".", trimmed != "..", seen.insert(trimmed).inserted
      else {
        return nil
      }
      return trimmed
    }
  }
}

nonisolated struct ProjectWorkspaceAgentGuideWriter: Sendable {
  var write: @Sendable (_ workspace: ProjectWorkspace, _ rootURL: URL) async throws -> Void
}
