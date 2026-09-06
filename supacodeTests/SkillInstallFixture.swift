import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

/// A temporary skills bundle plus a temporary home with `~/.claude` and `~/.agents` detected
/// and `~/.codex` absent. The real `~/.claude`, `~/.codex`, and `~/.agents` are never touched.
struct SkillInstallFixture {
  let root: URL
  let home: URL
  let client: SkillInstallClient

  init() throws {
    root =
      FileManager.default.temporaryDirectory
      .appending(path: "prowl-skill-install-\(UUID().uuidString)", directoryHint: .isDirectory)
      .standardizedFileURL
    home = root.appending(path: "home", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home.appending(path: ".agents"), withIntermediateDirectories: true)
    let resources = root.appending(path: "Resources", directoryHint: .isDirectory)
    let skillsRoot = resources.appending(path: "skills", directoryHint: .isDirectory)
    try Self.writeSkill(id: "prowl-cli", name: "Prowl CLI", audience: nil, skillsRoot: skillsRoot)
    try Self.writeSkill(id: "reviewer", name: "Reviewer", audience: "workflow", skillsRoot: skillsRoot)
    client = SkillInstallClient.live(resourcesURL: resources, userRoot: home)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }

  func skill(_ id: String) throws -> BundledSkill {
    try #require(try client.bundledSkills().first { $0.id == id })
  }

  func target(_ id: String) throws -> SkillInstallTarget {
    try #require(SkillInstallTarget.target(id: id))
  }

  func skillDirectory(_ id: String) -> String {
    root.appending(path: "Resources/skills/\(id)", directoryHint: .notDirectory).path(percentEncoded: false)
  }

  func linkPath(target: String, skill: String) -> String {
    home.appending(path: "\(target)/skills/\(skill)").path(percentEncoded: false)
  }

  func link(target: String, skill: String, to destination: String) throws {
    let skillsDirectory = home.appending(path: "\(target)/skills", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: linkPath(target: target, skill: skill), withDestinationPath: destination)
  }

  func makeDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  /// Synced dotfiles: `~/.claude/skills` and `~/.codex/skills` both symlink to one folder.
  func aliasClaudeAndCodexSkills() throws -> URL {
    let shared = root.appending(path: "skills-shared", directoryHint: .isDirectory)
    try makeDirectory(shared)
    try makeDirectory(home.appending(path: ".codex"))
    for target in [".claude", ".codex"] {
      try FileManager.default.createSymbolicLink(
        at: home.appending(path: "\(target)/skills"), withDestinationURL: shared)
    }
    return shared
  }

  func isSymlink(_ path: String) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
      == .typeSymbolicLink
  }

  private static func writeSkill(id: String, name: String, audience: String?, skillsRoot: URL) throws {
    let directory = skillsRoot.appending(path: id, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var frontmatter = "---\nname: \(name)\ndescription: \(name) description.\n"
    if let audience {
      frontmatter += "metadata:\n  prowl-install: \(audience)\n"
    }
    frontmatter += "---\n"
    try Data(frontmatter.utf8).write(to: directory.appending(path: "SKILL.md"))
  }
}
