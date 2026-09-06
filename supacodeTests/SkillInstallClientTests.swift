import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

/// Exercises the live client against a temporary skills root and a temporary home; the real
/// `~/.claude`, `~/.codex`, and `~/.agents` are never read or written.
struct SkillInstallClientTests {
  @Test func bundledSkillsListsEveryAudienceInBundleOrder() throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }

    let skills = try fixture.client.bundledSkills()

    #expect(skills.map(\.id) == ["prowl-cli", "reviewer"])
    #expect(skills.map(\.audience) == [.user, .workflow])
    #expect(ProwlSkillInstaller.sourcePath(skills[0]) == fixture.skillDirectory("prowl-cli"))
  }

  @Test func bundledSkillsFailsWhenTheBundleIsMissing() throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    let client = SkillInstallClient.live(
      resourcesURL: fixture.root.appending(path: "no-resources", directoryHint: .isDirectory),
      userRoot: fixture.home
    )

    #expect(throws: SkillInstallError.self) {
      try client.bundledSkills()
    }
    do {
      _ = try client.bundledSkills()
    } catch let error as SkillInstallError {
      #expect(error.message.contains("Bundled skills were not found"))
    }
  }

  @Test func bundledSkillsFailsWithoutAResourcesURL() throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    let client = SkillInstallClient.live(resourcesURL: nil, userRoot: fixture.home)

    #expect(throws: SkillInstallError.self) {
      try client.bundledSkills()
    }
  }

  @Test func statusReportsDetectionAndAllFourStates() throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    let skill = try fixture.skill("prowl-cli")
    try fixture.link(target: ".claude", skill: "prowl-cli", to: fixture.skillDirectory("prowl-cli"))
    try fixture.makeDirectory(fixture.home.appending(path: ".agents/skills/prowl-cli"))

    let claude = fixture.client.status(skill, try fixture.target("claude"))
    #expect(claude.detected)
    #expect(claude.linkPath == fixture.linkPath(target: ".claude", skill: "prowl-cli"))
    #expect(claude.status == .installed(path: claude.linkPath))

    let codex = fixture.client.status(skill, try fixture.target("codex"))
    #expect(!codex.detected, "~/.codex does not exist in the fixture")
    #expect(codex.status == .notInstalled)

    let agents = fixture.client.status(skill, try fixture.target("agents"))
    #expect(agents.status == .installedDifferentSource(path: agents.linkPath, destination: nil))

    let gone = fixture.root.appending(path: "gone").path(percentEncoded: false)
    try fixture.link(target: ".claude", skill: "reviewer", to: gone)
    let broken = fixture.client.status(try fixture.skill("reviewer"), try fixture.target("claude"))
    #expect(broken.status == .broken(path: broken.linkPath, destination: gone))
  }

  @Test func statusNamesTheOtherSourceOfAForeignLink() throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    let debugBuild = fixture.root.appending(path: "DerivedData/skills/prowl-cli", directoryHint: .isDirectory)
    try fixture.makeDirectory(debugBuild)
    let debugPath = debugBuild.path(percentEncoded: false).trimmingTrailingPathSeparator()
    try fixture.link(target: ".claude", skill: "prowl-cli", to: debugPath)

    let status = fixture.client.status(try fixture.skill("prowl-cli"), try fixture.target("claude"))

    #expect(status.status == .installedDifferentSource(path: status.linkPath, destination: debugPath))
  }

  @Test func installCreatesTheSkillsDirectoryAndLinksTheBundledSkill() async throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    let skill = try fixture.skill("prowl-cli")

    try await fixture.client.install(skill, try fixture.target("claude"))

    let linkPath = fixture.linkPath(target: ".claude", skill: "prowl-cli")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linkPath) == fixture.skillDirectory("prowl-cli"))
    #expect(fixture.client.status(skill, try fixture.target("claude")).status == .installed(path: linkPath))
  }

  @Test func installReplacesForeignAndDanglingLinks() async throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    let skill = try fixture.skill("prowl-cli")
    let other = fixture.root.appending(path: "other", directoryHint: .isDirectory)
    try fixture.makeDirectory(other)
    try fixture.link(target: ".claude", skill: "prowl-cli", to: other.path(percentEncoded: false))
    try fixture.link(target: ".agents", skill: "prowl-cli", to: fixture.root.appending(path: "gone").path())

    try await fixture.client.install(skill, try fixture.target("claude"))
    try await fixture.client.install(skill, try fixture.target("agents"))

    for target in [".claude", ".agents"] {
      let linkPath = fixture.linkPath(target: target, skill: "prowl-cli")
      #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: linkPath) == fixture.skillDirectory("prowl-cli"))
    }
    #expect(
      FileManager.default.fileExists(atPath: other.path(percentEncoded: false)), "The other source is never removed")
  }

  @Test func installRefusesARealDirectoryWithoutTouchingIt() async throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    let skill = try fixture.skill("prowl-cli")
    let realDirectory = fixture.home.appending(path: ".claude/skills/prowl-cli", directoryHint: .isDirectory)
    try fixture.makeDirectory(realDirectory)
    try Data("keep".utf8).write(to: realDirectory.appending(path: "SKILL.md"))

    await #expect(throws: SkillInstallError.self) {
      try await fixture.client.install(skill, try fixture.target("claude"))
    }
    do {
      try await fixture.client.install(skill, try fixture.target("claude"))
    } catch let error as SkillInstallError {
      #expect(error.message.contains("real file or directory"))
      #expect(error.message.contains("manually"))
    }
    #expect(try Data(contentsOf: realDirectory.appending(path: "SKILL.md")) == Data("keep".utf8))
    #expect(!fixture.isSymlink(realDirectory.path(percentEncoded: false)))
  }

  @Test func uninstallRemovesLinksOnlyAndReportsMissingOnes() async throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    let skill = try fixture.skill("prowl-cli")
    try fixture.link(target: ".claude", skill: "prowl-cli", to: fixture.skillDirectory("prowl-cli"))
    try fixture.link(target: ".agents", skill: "prowl-cli", to: fixture.root.appending(path: "gone").path())

    try await fixture.client.uninstall(skill, try fixture.target("claude"))
    try await fixture.client.uninstall(skill, try fixture.target("agents"))

    #expect(
      (try? FileManager.default.attributesOfItem(atPath: fixture.linkPath(target: ".claude", skill: "prowl-cli")))
        == nil)
    #expect(
      (try? FileManager.default.attributesOfItem(atPath: fixture.linkPath(target: ".agents", skill: "prowl-cli")))
        == nil)
    #expect(FileManager.default.fileExists(atPath: fixture.skillDirectory("prowl-cli")), "The bundled skill stays")

    do {
      try await fixture.client.uninstall(skill, try fixture.target("claude"))
      Issue.record("Expected uninstall to fail for an empty slot")
    } catch let error as SkillInstallError {
      #expect(error.message.contains("No skill link"))
    }
  }

  @Test func uninstallRefusesARealDirectory() async throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    let skill = try fixture.skill("prowl-cli")
    let realDirectory = fixture.home.appending(path: ".claude/skills/prowl-cli", directoryHint: .isDirectory)
    try fixture.makeDirectory(realDirectory)

    do {
      try await fixture.client.uninstall(skill, try fixture.target("claude"))
      Issue.record("Expected uninstall to refuse a real directory")
    } catch let error as SkillInstallError {
      #expect(error.message.contains("real file or directory"))
    }
    #expect(FileManager.default.fileExists(atPath: realDirectory.path(percentEncoded: false)))
  }

  @Test func aliasedTargetsShareOneLink() async throws {
    let fixture = try SkillInstallFixture()
    defer { fixture.cleanup() }
    let skill = try fixture.skill("prowl-cli")
    let shared = try fixture.aliasClaudeAndCodexSkills()

    try await fixture.client.install(skill, try fixture.target("claude"))

    let codex = fixture.client.status(skill, try fixture.target("codex"))
    #expect(codex.detected)
    #expect(codex.status == .installed(path: codex.linkPath), "The codex chip sees the link installed through claude")
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: shared.appending(path: "prowl-cli").path())
        == fixture.skillDirectory("prowl-cli")
    )

    try await fixture.client.uninstall(skill, try fixture.target("codex"))

    #expect(fixture.client.status(skill, try fixture.target("claude")).status == .notInstalled)
  }
}
