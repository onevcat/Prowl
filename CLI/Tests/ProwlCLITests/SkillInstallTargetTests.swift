import Foundation
import ProwlCLIShared
import XCTest

final class SkillInstallTargetTests: XCTestCase {
  func testExactV1TargetDefinitions() {
    XCTAssertEqual(SkillInstallTarget.all.map(\.id), ["claude", "codex", "agents"])
    XCTAssertEqual(
      SkillInstallTarget.all.map(\.userDirectory),
      [".claude/skills", ".codex/skills", ".agents/skills"]
    )
    XCTAssertEqual(
      SkillInstallTarget.all.map(\.projectDirectory),
      [".claude/skills", ".codex/skills", ".agents/skills"]
    )
    XCTAssertEqual(SkillInstallTarget.target(id: "codex")?.displayName, "Codex")
    XCTAssertNil(SkillInstallTarget.target(id: "cursor"))
  }

  func testSkillsDirectoryResolvesUnderTheScopeRoot() throws {
    let home = URL(filePath: "/tmp/home", directoryHint: .isDirectory)
    let repo = URL(filePath: "/tmp/repo", directoryHint: .isDirectory)
    let target = try XCTUnwrap(SkillInstallTarget.target(id: "claude"))

    XCTAssertEqual(
      target.skillsDirectoryURL(scope: .user, root: home).path(percentEncoded: false).trimmingTrailingPathSeparator(),
      "/tmp/home/.claude/skills"
    )
    XCTAssertEqual(
      target.skillsDirectoryURL(scope: .project, root: repo).path(percentEncoded: false)
        .trimmingTrailingPathSeparator(),
      "/tmp/repo/.claude/skills"
    )
  }

  func testDetectionRequiresTheParentDirectoryOnly() throws {
    try withTemporaryDirectory { home in
      try FileManager.default.createDirectory(
        at: home.appending(path: ".claude"), withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: home.appending(path: ".agents/skills"), withIntermediateDirectories: true)
      try Data().write(to: home.appending(path: ".codex"))

      let detected = SkillInstallTarget.all.filter { $0.isDetected(scope: .user, root: home) }.map(\.id)

      XCTAssertEqual(detected, ["claude", "agents"])
    }
  }

  func testDetectionAppliesTheSameParentRuleToProjectScope() throws {
    try withTemporaryDirectory { repo in
      try FileManager.default.createDirectory(
        at: repo.appending(path: ".codex"), withIntermediateDirectories: true)

      let detected = SkillInstallTarget.all.filter { $0.isDetected(scope: .project, root: repo) }.map(\.id)

      XCTAssertEqual(detected, ["codex"])
    }
  }

  func testInstallerCreatesTargetDirectoryAndRoundTrips() throws {
    try withTemporaryDirectory { root in
      let home = root.appending(path: "home", directoryHint: .isDirectory)
      let skill = try makeSkill(root: root, id: "prowl-cli")
      let target = try XCTUnwrap(SkillInstallTarget.target(id: "codex"))
      let linkPath = home.appending(path: ".codex/skills/prowl-cli").path(percentEncoded: false)

      let before = ProwlSkillInstaller.status(skill: skill, target: target, scope: .user, root: home)
      XCTAssertEqual(
        before, SkillTargetStatus(target: target, detected: false, linkPath: linkPath, status: .notInstalled))

      let installed = try ProwlSkillInstaller.install(skill: skill, target: target, scope: .user, root: home)
      XCTAssertEqual(installed.status, .installed(path: linkPath))
      XCTAssertTrue(installed.detected)
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(atPath: linkPath),
        root.appending(path: "skills/prowl-cli", directoryHint: .notDirectory).path(percentEncoded: false)
      )

      let removed = try ProwlSkillInstaller.uninstall(skill: skill, target: target, scope: .user, root: home)
      XCTAssertEqual(removed.status, .notInstalled)
      XCTAssertFalse(FileManager.default.fileExists(atPath: linkPath))
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: home.appending(path: ".codex/skills").path(percentEncoded: false)),
        "Uninstall removes the link only, never the target directory"
      )
    }
  }

  func testInstallerReportsBrokenAndDifferentSourceLinks() throws {
    try withTemporaryDirectory { root in
      let home = root.appending(path: "home", directoryHint: .isDirectory)
      let skill = try makeSkill(root: root, id: "prowl-cli")
      let target = try XCTUnwrap(SkillInstallTarget.target(id: "claude"))
      let skillsDirectory = home.appending(path: ".claude/skills")
      try FileManager.default.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
      let linkPath = skillsDirectory.appending(path: "prowl-cli").path(percentEncoded: false)
      try FileManager.default.createSymbolicLink(
        atPath: linkPath,
        withDestinationPath: root.appending(path: "gone").path(percentEncoded: false)
      )

      XCTAssertEqual(
        ProwlSkillInstaller.status(skill: skill, target: target, scope: .user, root: home).status,
        .broken(path: linkPath, destination: root.appending(path: "gone").path(percentEncoded: false))
      )

      try FileManager.default.removeItem(atPath: linkPath)
      let other = root.appending(path: "other")
      try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        atPath: linkPath, withDestinationPath: other.path(percentEncoded: false))

      XCTAssertEqual(
        ProwlSkillInstaller.status(skill: skill, target: target, scope: .user, root: home).status,
        .installedDifferentSource(path: linkPath, destination: other.path(percentEncoded: false))
      )
    }
  }

  func testInstallerRefusesProjectTargetsThatResolveOutsideTheRoot() throws {
    try withTemporaryDirectory { root in
      let repo = root.appending(path: "repo", directoryHint: .isDirectory)
      let external = root.appending(path: "external", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: repo.appending(path: ".codex"), withDestinationURL: external)
      let skill = try makeSkill(root: root, id: "prowl-cli")
      let target = try XCTUnwrap(SkillInstallTarget.target(id: "codex"))
      let escapingPath = repo.appending(path: ".codex", directoryHint: .notDirectory).path(percentEncoded: false)

      XCTAssertEqual(
        ProwlSkillInstaller.projectBoundaryViolation(target: target, root: repo),
        escapingPath
      )
      XCTAssertNil(
        ProwlSkillInstaller.projectBoundaryViolation(
          target: try XCTUnwrap(SkillInstallTarget.target(id: "claude")), root: repo)
      )
      XCTAssertThrowsError(
        try ProwlSkillInstaller.install(skill: skill, target: target, scope: .project, root: repo)
      ) { error in
        XCTAssertEqual(error as? SymlinkInstallError, .conflict(path: escapingPath))
      }
      XCTAssertThrowsError(
        try ProwlSkillInstaller.uninstall(skill: skill, target: target, scope: .project, root: repo)
      ) { error in
        XCTAssertEqual(error as? SymlinkInstallError, .conflict(path: escapingPath))
      }
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path(percentEncoded: false)), [])
      XCTAssertNoThrow(try ProwlSkillInstaller.install(skill: skill, target: target, scope: .user, root: repo))
    }
  }

  // MARK: - Helpers

  private func withTemporaryDirectory(_ operation: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-skill-targets-\(UUID().uuidString)", directoryHint: .isDirectory)
      .standardizedFileURL
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try operation(root)
  }

  private func makeSkill(root: URL, id: String) throws -> BundledSkill {
    let directory = root.appending(path: "skills/\(id)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("---\nname: \(id)\ndescription: \(id).\n---\n".utf8)
      .write(to: directory.appending(path: "SKILL.md"))
    return BundledSkill(id: id, name: id, description: "\(id).", audience: .user, directoryURL: directory)
  }
}
