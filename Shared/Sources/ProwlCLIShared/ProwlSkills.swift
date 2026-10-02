import Foundation

nonisolated public enum ProwlSkillAudience: String, Codable, Equatable, Sendable {
  case user
  case workflow
}

nonisolated public struct BundledSkill: Equatable, Sendable {
  public let id: String
  public let name: String
  /// The agent-facing description from the frontmatter, including trigger phrasing.
  public let description: String
  /// `metadata.prowl-summary`: a short human-facing summary for UI surfaces; nil when absent.
  public let summary: String?
  public let audience: ProwlSkillAudience
  public let directoryURL: URL

  public init(
    id: String,
    name: String,
    description: String,
    audience: ProwlSkillAudience,
    directoryURL: URL,
    summary: String? = nil
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.summary = summary
    self.audience = audience
    self.directoryURL = directoryURL
  }
}

nonisolated public enum ProwlSkillsError: Error, Equatable, Sendable, LocalizedError {
  public enum Code: String, Equatable, Sendable {
    case bundleNotFound = "BUNDLE_NOT_FOUND"
    case invalidFrontmatter = "INVALID_SKILL_FRONTMATTER"
  }

  case bundleNotFound(path: String)
  case invalidFrontmatter(path: String, reason: String)

  public var code: Code {
    switch self {
    case .bundleNotFound:
      .bundleNotFound
    case .invalidFrontmatter:
      .invalidFrontmatter
    }
  }

  public var errorDescription: String? {
    switch self {
    case .bundleNotFound(let path):
      "Bundled skills were not found at \(path)."
    case .invalidFrontmatter(let path, let reason):
      "Invalid skill frontmatter at \(path): \(reason)"
    }
  }
}

nonisolated public enum ProwlSkills {
  public static func bundled(resourcesURL: URL) throws -> [BundledSkill] {
    try bundled(
      skillsURL: resourcesURL.appending(path: "skills", directoryHint: .isDirectory)
    )
  }

  public static func skill(id: String, resourcesURL: URL) throws -> BundledSkill? {
    try bundled(resourcesURL: resourcesURL).first { $0.id == id }
  }

  public static func bundledForCLI(
    executableURL: URL,
    environment: [String: String]
  ) throws -> [BundledSkill] {
    if let overridePath = environment["PROWL_SKILLS_DIR"] {
      guard !overridePath.isEmpty else {
        throw ProwlSkillsError.bundleNotFound(path: overridePath)
      }
      return try bundled(
        skillsURL: URL(filePath: overridePath, directoryHint: .isDirectory)
      )
    }

    let resolvedExecutableURL = executableURL.standardizedFileURL.resolvingSymlinksInPath()
    let executableDirectory = resolvedExecutableURL.deletingLastPathComponent()
    guard resolvedExecutableURL.lastPathComponent == "prowl",
      executableDirectory.lastPathComponent == "prowl-cli"
    else {
      throw ProwlSkillsError.bundleNotFound(
        path: resolvedExecutableURL.path(percentEncoded: false)
      )
    }
    return try bundled(resourcesURL: executableDirectory.deletingLastPathComponent())
  }

  private static func bundled(skillsURL: URL) throws -> [BundledSkill] {
    let standardizedSkillsURL = skillsURL.standardizedFileURL
    let skillsPath = standardizedSkillsURL.path(percentEncoded: false)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: skillsPath, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw ProwlSkillsError.bundleNotFound(path: skillsPath)
    }

    let contents: [URL]
    do {
      contents = try FileManager.default.contentsOfDirectory(
        at: standardizedSkillsURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      throw ProwlSkillsError.bundleNotFound(path: skillsPath)
    }

    let directories =
      contents
      .filter { url in
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }

    return try directories.compactMap { directoryURL in
      let skillFileURL = directoryURL.appending(path: "SKILL.md", directoryHint: .notDirectory)
      guard FileManager.default.fileExists(atPath: skillFileURL.path(percentEncoded: false)) else {
        return nil
      }
      return try parseSkill(
        id: directoryURL.lastPathComponent,
        directoryURL: directoryURL.standardizedFileURL,
        skillFileURL: skillFileURL
      )
    }
  }

  private static func parseSkill(
    id: String,
    directoryURL: URL,
    skillFileURL: URL
  ) throws -> BundledSkill {
    let skillPath = skillFileURL.path(percentEncoded: false)
    let data: Data
    do {
      data = try Data(contentsOf: skillFileURL)
    } catch {
      throw ProwlSkillsError.invalidFrontmatter(
        path: skillPath,
        reason: "SKILL.md could not be read"
      )
    }
    guard let source = String(data: data, encoding: .utf8) else {
      throw ProwlSkillsError.invalidFrontmatter(
        path: skillPath,
        reason: "SKILL.md is not valid UTF-8"
      )
    }

    let frontmatter = try parseFrontmatter(source, path: skillPath)
    return BundledSkill(
      id: id,
      name: frontmatter.name,
      description: frontmatter.description,
      audience: frontmatter.audience,
      directoryURL: directoryURL,
      summary: frontmatter.summary
    )
  }

  private static func parseFrontmatter(_ source: String, path: String) throws -> ParsedFrontmatter {
    let normalizedSource =
      source
      .replacing("\r\n", with: "\n")
      .replacing("\r", with: "\n")
    let lines = normalizedSource.split(separator: "\n", omittingEmptySubsequences: false).map(
      String.init)
    guard lines.first == "---",
      let closingIndex = lines.indices.dropFirst().first(where: { lines[$0] == "---" })
    else {
      throw invalidFrontmatter(path: path, reason: "missing frontmatter delimiters")
    }

    let frontmatterLines = Array(lines[1..<closingIndex])
    var name: String?
    var description: String?
    var metadata = ParsedMetadata()
    var index = 0

    while index < frontmatterLines.count {
      let line = frontmatterLines[index]
      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        index += 1
        continue
      }
      guard indentation(of: line) == 0,
        let (key, value) = keyValue(in: line),
        !key.isEmpty
      else {
        throw invalidFrontmatter(path: path, reason: "malformed top-level field")
      }

      try validateTopLevelKey(key, path: path)

      switch key {
      case "name":
        guard name == nil, !value.isEmpty else {
          throw invalidFrontmatter(path: path, reason: "name must be a non-empty scalar")
        }
        name = value
        index += 1

      case "description":
        guard description == nil else {
          throw invalidFrontmatter(path: path, reason: "description is duplicated")
        }
        if value == ">-" {
          let result = try foldedDescription(
            lines: frontmatterLines,
            startIndex: index + 1,
            path: path
          )
          description = result.value
          index = result.nextIndex
        } else {
          guard !value.isEmpty else {
            throw invalidFrontmatter(
              path: path, reason: "description must be a non-empty scalar or >- block")
          }
          description = value
          index += 1
        }

      case "metadata":
        guard value.isEmpty else {
          throw invalidFrontmatter(path: path, reason: "metadata must be a map")
        }
        index = try parseMetadata(
          lines: frontmatterLines,
          startIndex: index + 1,
          into: &metadata,
          path: path
        )

      default:
        index += 1
      }
    }

    guard let name else {
      throw invalidFrontmatter(path: path, reason: "name is missing")
    }
    guard let description else {
      throw invalidFrontmatter(path: path, reason: "description is missing")
    }
    return ParsedFrontmatter(
      name: name,
      description: description,
      audience: metadata.audience,
      summary: metadata.summary
    )
  }

  private static func foldedDescription(
    lines: [String],
    startIndex: Int,
    path: String
  ) throws -> (value: String, nextIndex: Int) {
    var index = startIndex
    var blockLines: [String] = []
    while index < lines.count {
      let line = lines[index]
      if !line.trimmingCharacters(in: .whitespaces).isEmpty, indentation(of: line) == 0 {
        break
      }
      blockLines.append(line)
      index += 1
    }

    let nonEmptyLines = blockLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard let blockIndent = nonEmptyLines.compactMap(indentation).min(), blockIndent > 0 else {
      throw invalidFrontmatter(path: path, reason: "folded description is empty or malformed")
    }

    var paragraphs: [String] = []
    var paragraphLines: [String] = []
    for line in blockLines {
      let stripped = String(line.dropFirst(min(blockIndent, line.count)))
        .trimmingCharacters(in: .whitespaces)
      if stripped.isEmpty {
        if !paragraphLines.isEmpty {
          paragraphs.append(paragraphLines.joined(separator: " "))
          paragraphLines.removeAll(keepingCapacity: true)
        }
      } else {
        paragraphLines.append(stripped)
      }
    }
    if !paragraphLines.isEmpty {
      paragraphs.append(paragraphLines.joined(separator: " "))
    }

    let value = paragraphs.joined(separator: "\n")
    guard !value.isEmpty else {
      throw invalidFrontmatter(path: path, reason: "folded description is empty")
    }
    return (value, index)
  }

  /// Parses the `metadata:` map's direct children into `state` and returns the index of the first
  /// line after the map. A second `metadata:` block continues the same state, so duplicates are
  /// still rejected.
  private static func parseMetadata(
    lines: [String],
    startIndex: Int,
    into state: inout ParsedMetadata,
    path: String
  ) throws -> Int {
    var directFieldIndent: Int?
    var index = startIndex

    while index < lines.count {
      let line = lines[index]
      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        index += 1
        continue
      }
      guard let fieldIndent = indentation(of: line) else {
        throw invalidFrontmatter(path: path, reason: "metadata uses invalid indentation")
      }
      if fieldIndent == 0 {
        break
      }
      if directFieldIndent == nil {
        directFieldIndent = fieldIndent
      }
      guard let directFieldIndent, fieldIndent == directFieldIndent else {
        throw invalidFrontmatter(
          path: path,
          reason: "metadata fields must use consistent direct-child indentation"
        )
      }
      guard let (key, value) = keyValue(in: line), !key.isEmpty else {
        throw invalidFrontmatter(path: path, reason: "metadata contains a malformed field")
      }
      switch key {
      case "prowl-install":
        guard !state.audienceWasSet, let parsedAudience = ProwlSkillAudience(rawValue: value) else {
          throw invalidFrontmatter(
            path: path, reason: "metadata.prowl-install must be user or workflow")
        }
        state.audience = parsedAudience
        state.audienceWasSet = true
      case "prowl-summary":
        guard state.summary == nil, !value.isEmpty else {
          throw invalidFrontmatter(
            path: path, reason: "metadata.prowl-summary must be a single non-empty scalar")
        }
        state.summary = value
      default:
        break
      }
      index += 1
    }

    return index
  }

  private static func validateTopLevelKey(_ key: String, path: String) throws {
    guard key != "prowl-install" else {
      throw invalidFrontmatter(
        path: path,
        reason: "prowl-install must be a direct child of metadata"
      )
    }
  }

  private static func keyValue(in line: String) -> (key: String, value: String)? {
    guard let separator = line.firstIndex(of: ":") else {
      return nil
    }
    let key = line[..<separator].trimmingCharacters(in: .whitespaces)
    let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
    return (key, value)
  }

  private static func indentation(of line: String) -> Int? {
    var indentation = 0
    for character in line {
      switch character {
      case " ":
        indentation += 1
      case "\t":
        return nil
      default:
        return indentation
      }
    }
    return indentation
  }

  private static func invalidFrontmatter(path: String, reason: String) -> ProwlSkillsError {
    .invalidFrontmatter(path: path, reason: reason)
  }
}

nonisolated private struct ParsedFrontmatter {
  let name: String
  let description: String
  let audience: ProwlSkillAudience
  let summary: String?
}

nonisolated private struct ParsedMetadata {
  var audience = ProwlSkillAudience.user
  var audienceWasSet = false
  var summary: String?
}
