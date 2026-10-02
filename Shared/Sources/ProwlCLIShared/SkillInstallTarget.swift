import Foundation

nonisolated public enum ProwlSkillScope: String, Codable, Equatable, Sendable {
  case user
  case project
}

/// One verified agent skill directory (065 S0). Directories are relative to the scope root:
/// the user's home directory or a project root.
nonisolated public struct SkillInstallTarget: Equatable, Sendable, Identifiable {
  public let id: String
  public let displayName: String
  public let userDirectory: String
  public let projectDirectory: String

  public static let all: [SkillInstallTarget] = [
    SkillInstallTarget(
      id: "claude",
      displayName: "Claude Code",
      userDirectory: ".claude/skills",
      projectDirectory: ".claude/skills"
    ),
    SkillInstallTarget(
      id: "codex",
      displayName: "Codex",
      userDirectory: ".codex/skills",
      projectDirectory: ".codex/skills"
    ),
    SkillInstallTarget(
      id: "agents",
      displayName: "Shared agents directory",
      userDirectory: ".agents/skills",
      projectDirectory: ".agents/skills"
    ),
  ]

  public static func target(id: String) -> SkillInstallTarget? {
    all.first { $0.id == id }
  }

  public func skillsDirectoryURL(scope: ProwlSkillScope, root: URL) -> URL {
    let directory =
      switch scope {
      case .user: userDirectory
      case .project: projectDirectory
      }
    return root.appending(path: directory, directoryHint: .isDirectory)
  }

  /// A target is detected when the parent of its skills directory (for example `~/.codex`)
  /// exists, so a runtime that was never set up is not selected by default.
  public func isDetected(scope: ProwlSkillScope, root: URL) -> Bool {
    let parent = skillsDirectoryURL(scope: scope, root: root).deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: parent.path(percentEncoded: false), isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}

nonisolated public struct SkillTargetStatus: Equatable, Sendable {
  public let target: SkillInstallTarget
  public let detected: Bool
  public let linkPath: String
  public let status: SymlinkInstallStatus

  public init(target: SkillInstallTarget, detected: Bool, linkPath: String, status: SymlinkInstallStatus) {
    self.target = target
    self.detected = detected
    self.linkPath = linkPath
    self.status = status
  }
}

/// Skill × target link operations shared by `prowl skills` and the Settings UI.
nonisolated public enum ProwlSkillInstaller {
  public static func status(
    skill: BundledSkill,
    target: SkillInstallTarget,
    scope: ProwlSkillScope,
    root: URL
  ) -> SkillTargetStatus {
    let linkPath = linkPath(skill: skill, target: target, scope: scope, root: root)
    return SkillTargetStatus(
      target: target,
      detected: target.isDetected(scope: scope, root: root),
      linkPath: linkPath,
      status: SymlinkInstaller.status(linkPath: linkPath, source: sourcePath(skill))
    )
  }

  /// Creates the target directory when missing and links the bundled skill directory.
  /// In project scope, a target directory that resolves outside the project root is refused.
  public static func install(
    skill: BundledSkill,
    target: SkillInstallTarget,
    scope: ProwlSkillScope,
    root: URL
  ) throws -> SkillTargetStatus {
    try enforceProjectBoundary(target: target, scope: scope, root: root)
    try SymlinkInstaller.install(
      source: sourcePath(skill),
      linkPath: linkPath(skill: skill, target: target, scope: scope, root: root)
    )
    return status(skill: skill, target: target, scope: scope, root: root)
  }

  public static func uninstall(
    skill: BundledSkill,
    target: SkillInstallTarget,
    scope: ProwlSkillScope,
    root: URL
  ) throws -> SkillTargetStatus {
    try enforceProjectBoundary(target: target, scope: scope, root: root)
    try SymlinkInstaller.uninstall(linkPath: linkPath(skill: skill, target: target, scope: scope, root: root))
    return status(skill: skill, target: target, scope: scope, root: root)
  }

  /// The first target path component (`<root>/.codex` or `<root>/.codex/skills`) that exists but
  /// resolves outside the canonical project root, or `nil` when the slot stays inside the project.
  /// A repository-controlled symlink must not redirect a project-scoped link into another folder;
  /// user scope deliberately follows symlinks because synced skill folders are an approved setup.
  public static func projectBoundaryViolation(target: SkillInstallTarget, root: URL) -> String? {
    let canonicalRoot = realPath(root)
    let skillsDirectory = target.skillsDirectoryURL(scope: .project, root: root)
    for candidate in [skillsDirectory.deletingLastPathComponent(), skillsDirectory] {
      let path = candidate.path(percentEncoded: false).trimmingTrailingPathSeparator()
      guard (try? FileManager.default.attributesOfItem(atPath: path)) != nil else { continue }
      let resolved = realPath(candidate)
      if resolved != canonicalRoot, !resolved.hasPrefix(canonicalRoot + "/") {
        return path
      }
    }
    return nil
  }

  private static func enforceProjectBoundary(
    target: SkillInstallTarget,
    scope: ProwlSkillScope,
    root: URL
  ) throws {
    guard scope == .project, let path = projectBoundaryViolation(target: target, root: root) else { return }
    throw SymlinkInstallError.conflict(path: path)
  }

  private static func realPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false).trimmingTrailingPathSeparator()
  }

  public static func sourcePath(_ skill: BundledSkill) -> String {
    skill.directoryURL.path(percentEncoded: false).trimmingTrailingPathSeparator()
  }

  private static func linkPath(
    skill: BundledSkill,
    target: SkillInstallTarget,
    scope: ProwlSkillScope,
    root: URL
  ) -> String {
    target.skillsDirectoryURL(scope: scope, root: root)
      .appending(path: skill.id, directoryHint: .notDirectory)
      .path(percentEncoded: false)
      .trimmingTrailingPathSeparator()
  }
}
