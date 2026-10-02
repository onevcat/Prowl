import Foundation
import ProwlCLIShared
import XCTest

@testable import prowl

final class SkillsCommandExecutorTests: XCTestCase {
  // MARK: - list

  func testListReportsEverySkillAcrossEveryTargetWithDetectionAndAudience() throws {
    try withFixture { fixture in
      let payload = try fixture.executor.list()
      guard case .list(let list) = payload else { return XCTFail("Expected list payload") }

      XCTAssertEqual(list.skills.map(\.id), ["prowl-cli", "reviewer"])
      XCTAssertEqual(list.skills.map(\.audience), [.user, .workflow])
      XCTAssertEqual(list.skills[0].path, fixture.skillDirectory("prowl-cli"))
      XCTAssertEqual(list.skills[0].targets.map(\.id), ["claude", "codex", "agents"])
      XCTAssertEqual(list.skills[0].targets.map(\.detected), [true, false, true])
      XCTAssertEqual(list.skills[0].targets.map(\.status), [.notInstalled, .notInstalled, .notInstalled])
      XCTAssertEqual(list.skills[0].targets[0].path, fixture.linkPath(target: ".claude", skill: "prowl-cli"))
    }
  }

  func testListReportsAllFourStatuses() throws {
    try withFixture { fixture in
      try fixture.link(target: ".claude", skill: "prowl-cli", to: fixture.skillDirectory("prowl-cli"))
      try fixture.link(target: ".agents", skill: "prowl-cli", to: fixture.root.appending(path: "gone").path())
      try fixture.makeDirectory(fixture.home.appending(path: ".codex/skills/prowl-cli"))

      let payload = try fixture.executor.list()
      guard case .list(let list) = payload else { return XCTFail("Expected list payload") }

      XCTAssertEqual(
        list.skills[0].targets.map(\.status),
        [.installed, .installedDifferentSource, .broken]
      )
      XCTAssertEqual(
        list.skills[0].targets.map(\.destination),
        [nil, nil, fixture.root.appending(path: "gone").path(percentEncoded: false)],
        "A real directory has no destination; a dangling link names where the app used to be"
      )
      XCTAssertEqual(list.skills[1].targets.map(\.status), [.notInstalled, .notInstalled, .notInstalled])
    }
  }

  func testListNamesTheOtherSourceOfAForeignLink() throws {
    try withFixture { fixture in
      let debugBuild = fixture.root.appending(path: "DerivedData/skills/prowl-cli", directoryHint: .isDirectory)
      try fixture.makeDirectory(debugBuild)
      let debugPath = debugBuild.path(percentEncoded: false).trimmingTrailingPathSeparator()
      try fixture.link(target: ".claude", skill: "prowl-cli", to: debugPath)

      let payload = try fixture.executor.list()
      guard case .list(let list) = payload else { return XCTFail("Expected list payload") }

      XCTAssertEqual(list.skills[0].targets[0].status, .installedDifferentSource)
      XCTAssertEqual(list.skills[0].targets[0].destination, debugPath)
    }
  }

  // MARK: - install

  func testBareInstallLinksUserSkillsIntoDetectedTargetsOnly() throws {
    try withFixture { fixture in
      let payload = try fixture.executor.install(SkillsChangeRequest())
      guard case .install(let change) = payload else { return XCTFail("Expected install payload") }

      XCTAssertEqual(change.scope, .user)
      XCTAssertEqual(change.root, fixture.home.path(percentEncoded: false).trimmingTrailingPathSeparator())
      XCTAssertNil(change.note)
      XCTAssertEqual(
        change.results,
        [
          SkillsCommandResult(
            skill: "prowl-cli", target: "claude",
            path: fixture.linkPath(target: ".claude", skill: "prowl-cli"),
            before: .notInstalled, after: .installed),
          SkillsCommandResult(
            skill: "prowl-cli", target: "agents",
            path: fixture.linkPath(target: ".agents", skill: "prowl-cli"),
            before: .notInstalled, after: .installed),
        ]
      )
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(
          atPath: fixture.linkPath(target: ".claude", skill: "prowl-cli")),
        fixture.skillDirectory("prowl-cli")
      )
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: fixture.home.appending(path: ".codex").path()),
        "A bare install never creates an undetected target"
      )
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: fixture.linkPath(target: ".claude", skill: "reviewer")),
        "Workflow-audience skills are never installed by a bare install"
      )
    }
  }

  func testExplicitTargetCreatesUndetectedTargetDirectory() throws {
    try withFixture { fixture in
      let payload = try fixture.executor.install(
        SkillsChangeRequest(skillIDs: ["prowl-cli"], targetIDs: ["codex"]))
      guard case .install(let change) = payload else { return XCTFail("Expected install payload") }

      XCTAssertEqual(change.results.map(\.target), ["codex"])
      XCTAssertEqual(change.results.map(\.after), [.installed])
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(
          atPath: fixture.linkPath(target: ".codex", skill: "prowl-cli")),
        fixture.skillDirectory("prowl-cli")
      )
    }
  }

  func testInstallOrdersAndDeduplicatesExplicitSkillsAndTargets() throws {
    try withFixture { fixture in
      let payload = try fixture.executor.install(
        SkillsChangeRequest(
          skillIDs: ["prowl-cli", "prowl-cli"],
          targetIDs: ["agents", "claude", "agents"]))
      guard case .install(let change) = payload else { return XCTFail("Expected install payload") }

      XCTAssertEqual(change.results.map { "\($0.skill)→\($0.target)" }, ["prowl-cli→claude", "prowl-cli→agents"])
    }
  }

  func testInstallRepairsBrokenLinksAndLeavesInstalledLinksUnchanged() throws {
    try withFixture { fixture in
      try fixture.link(target: ".claude", skill: "prowl-cli", to: fixture.root.appending(path: "gone").path())
      try fixture.link(target: ".agents", skill: "prowl-cli", to: fixture.skillDirectory("prowl-cli"))

      let payload = try fixture.executor.install(SkillsChangeRequest(skillIDs: ["prowl-cli"]))
      guard case .install(let change) = payload else { return XCTFail("Expected install payload") }

      XCTAssertEqual(change.results.map(\.before), [.broken, .installed])
      XCTAssertEqual(change.results.map(\.after), [.installed, .installed])
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(
          atPath: fixture.linkPath(target: ".claude", skill: "prowl-cli")),
        fixture.skillDirectory("prowl-cli")
      )
    }
  }

  func testInstallRejectsUnknownSkillAndTarget() throws {
    try withFixture { fixture in
      assertExitError(code: CLIErrorCode.skillNotFound) {
        _ = try fixture.executor.install(SkillsChangeRequest(skillIDs: ["missing"]))
      }
      assertExitError(code: CLIErrorCode.targetNotFound) {
        _ = try fixture.executor.install(SkillsChangeRequest(targetIDs: ["cursor"]))
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linkPath(target: ".claude", skill: "prowl-cli")))
    }
  }

  func testInstallRefusesWorkflowAudienceSkills() throws {
    try withFixture { fixture in
      assertExitError(code: CLIErrorCode.skillNotInstallable) {
        _ = try fixture.executor.install(SkillsChangeRequest(skillIDs: ["prowl-cli", "reviewer"]))
      }
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: fixture.linkPath(target: ".claude", skill: "prowl-cli")),
        "Refusal happens before any link is created"
      )
    }
  }

  func testBareInstallWithoutDetectedTargetsFailsWithTargetNotFound() throws {
    try withFixture { fixture in
      try FileManager.default.removeItem(at: fixture.home.appending(path: ".claude"))
      try FileManager.default.removeItem(at: fixture.home.appending(path: ".agents"))

      assertExitError(code: CLIErrorCode.targetNotFound) {
        _ = try fixture.executor.install(SkillsChangeRequest())
      }
    }
  }

  func testInstallConflictIsDetectedBeforeAnyChange() throws {
    try withFixture { fixture in
      let realDirectory = fixture.home.appending(path: ".agents/skills/prowl-cli")
      try fixture.makeDirectory(realDirectory)
      try Data("keep".utf8).write(to: realDirectory.appending(path: "SKILL.md"))

      assertExitError(code: CLIErrorCode.installConflict) {
        _ = try fixture.executor.install(SkillsChangeRequest())
      }

      XCTAssertFalse(
        FileManager.default.fileExists(atPath: fixture.linkPath(target: ".claude", skill: "prowl-cli")),
        "The conflict-free target must not be modified when another target conflicts"
      )
      XCTAssertEqual(try Data(contentsOf: realDirectory.appending(path: "SKILL.md")), Data("keep".utf8))
    }
  }

  func testAliasedTargetsShareOneSlotWithoutFailingOrDoubleLinking() throws {
    try withFixture { fixture in
      // Synced dotfiles: ~/.claude/skills and ~/.codex/skills are symlinks to one shared folder.
      let shared = fixture.root.appending(path: "skills-shared", directoryHint: .isDirectory)
      try fixture.makeDirectory(shared)
      try fixture.makeDirectory(fixture.home.appending(path: ".codex"))
      for target in [".claude", ".codex"] {
        try FileManager.default.createSymbolicLink(
          at: fixture.home.appending(path: "\(target)/skills"), withDestinationURL: shared)
      }

      let install = try fixture.executor.install(SkillsChangeRequest(skillIDs: ["prowl-cli"]))
      guard case .install(let installed) = install else { return XCTFail("Expected install payload") }
      XCTAssertEqual(installed.results.map(\.target), ["claude", "codex", "agents"])
      XCTAssertEqual(installed.results.map(\.before), [.notInstalled, .installed, .notInstalled])
      XCTAssertEqual(installed.results.map(\.after), [.installed, .installed, .installed])
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(atPath: shared.appending(path: "prowl-cli").path()),
        fixture.skillDirectory("prowl-cli")
      )

      let uninstall = try fixture.executor.uninstall(SkillsChangeRequest(skillIDs: ["prowl-cli"]))
      guard case .uninstall(let removed) = uninstall else { return XCTFail("Expected uninstall payload") }
      XCTAssertEqual(removed.results.map(\.target), ["claude", "codex", "agents"])
      XCTAssertEqual(removed.results.map(\.before), [.installed, .notInstalled, .installed])
      XCTAssertEqual(removed.results.map(\.after), [.notInstalled, .notInstalled, .notInstalled])
      XCTAssertNil(try? FileManager.default.attributesOfItem(atPath: shared.appending(path: "prowl-cli").path()))
      XCTAssertNil(
        try? FileManager.default.attributesOfItem(
          atPath: fixture.home.appending(path: ".agents/skills/prowl-cli").path()),
        "Every slot is removed even though two of them alias the same link"
      )
    }
  }

  // MARK: - uninstall

  func testUninstallRemovesLinksAndSkipsAbsentOnes() throws {
    try withFixture { fixture in
      try fixture.link(target: ".claude", skill: "prowl-cli", to: fixture.skillDirectory("prowl-cli"))
      try fixture.link(target: ".agents", skill: "prowl-cli", to: fixture.root.appending(path: "gone").path())

      let payload = try fixture.executor.uninstall(SkillsChangeRequest())
      guard case .uninstall(let change) = payload else { return XCTFail("Expected uninstall payload") }

      XCTAssertEqual(change.results.map(\.target), ["claude", "agents"])
      XCTAssertEqual(change.results.map(\.before), [.installed, .broken])
      XCTAssertEqual(change.results.map(\.after), [.notInstalled, .notInstalled])
      XCTAssertFalse(fixture.isSymlink(fixture.linkPath(target: ".claude", skill: "prowl-cli")))
      XCTAssertFalse(fixture.isSymlink(fixture.linkPath(target: ".agents", skill: "prowl-cli")))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.skillDirectory("prowl-cli")))

      let again = try fixture.executor.uninstall(SkillsChangeRequest(skillIDs: ["prowl-cli"], targetIDs: ["codex"]))
      guard case .uninstall(let unchanged) = again else { return XCTFail("Expected uninstall payload") }
      XCTAssertEqual(unchanged.results.map(\.before), [.notInstalled])
      XCTAssertEqual(unchanged.results.map(\.after), [.notInstalled])
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: fixture.home.appending(path: ".codex").path()),
        "Uninstall never creates target directories"
      )
    }
  }

  func testUninstallRefusesRealDirectories() throws {
    try withFixture { fixture in
      try fixture.link(target: ".claude", skill: "prowl-cli", to: fixture.skillDirectory("prowl-cli"))
      try fixture.makeDirectory(fixture.home.appending(path: ".agents/skills/prowl-cli"))

      assertExitError(code: CLIErrorCode.installConflict) {
        _ = try fixture.executor.uninstall(SkillsChangeRequest())
      }
      XCTAssertTrue(
        fixture.isSymlink(fixture.linkPath(target: ".claude", skill: "prowl-cli")),
        "A conflict elsewhere leaves other links untouched"
      )
    }
  }

  // MARK: - path

  func testPathResolvesAnyAudienceAndRejectsUnknownSkills() throws {
    try withFixture { fixture in
      guard case .path(let user) = try fixture.executor.path(skillID: "prowl-cli") else {
        return XCTFail("Expected path payload")
      }
      XCTAssertEqual(user.skill.path, fixture.skillDirectory("prowl-cli"))
      XCTAssertEqual(user.skill.audience, .user)

      guard case .path(let workflow) = try fixture.executor.path(skillID: "reviewer") else {
        return XCTFail("Expected path payload")
      }
      XCTAssertEqual(workflow.skill.path, fixture.skillDirectory("reviewer"))
      XCTAssertEqual(workflow.skill.audience, .workflow)

      assertExitError(code: CLIErrorCode.skillNotFound) {
        _ = try fixture.executor.path(skillID: "../prowl-cli")
      }
    }
  }

  // MARK: - project scope

  func testProjectScopeUsesExplicitPathAndPrintsHygieneNoteOnce() throws {
    try withFixture { fixture in
      let repo = try fixture.makeRepository(name: "repo")
      try fixture.makeDirectory(repo.appending(path: ".claude"))
      let gitEntriesBefore = try fixture.gitEntries(repo)

      let payload = try fixture.executor.install(
        SkillsChangeRequest(scope: .project, projectPath: repo.path(percentEncoded: false)))
      guard case .install(let change) = payload else { return XCTFail("Expected install payload") }

      XCTAssertEqual(change.scope, .project)
      XCTAssertEqual(change.root, repo.path(percentEncoded: false).trimmingTrailingPathSeparator())
      XCTAssertEqual(change.results.map(\.target), ["claude"])
      XCTAssertEqual(
        change.results.map(\.path),
        [repo.appending(path: ".claude/skills/prowl-cli").path(percentEncoded: false)]
      )
      let note = try XCTUnwrap(change.note)
      XCTAssertTrue(note.contains(".git/info/exclude"))
      XCTAssertTrue(note.contains("absolute"))
      XCTAssertEqual(try fixture.gitEntries(repo), gitEntriesBefore, "Prowl never edits Git state")
    }
  }

  func testProjectScopeResolvesTheGitRootFromTheCurrentDirectory() throws {
    try withFixture { fixture in
      let repo = try fixture.makeRepository(name: "repo")
      let nested = repo.appending(path: "src/deep", directoryHint: .isDirectory)
      try fixture.makeDirectory(nested)

      let executor = fixture.executor(currentDirectory: nested)
      let payload = try executor.install(
        SkillsChangeRequest(skillIDs: ["prowl-cli"], targetIDs: ["codex"], scope: .project))
      guard case .install(let change) = payload else { return XCTFail("Expected install payload") }

      XCTAssertEqual(change.root, repo.path(percentEncoded: false).trimmingTrailingPathSeparator())
      XCTAssertEqual(
        change.results.map(\.path),
        [repo.appending(path: ".codex/skills/prowl-cli").path(percentEncoded: false)]
      )
    }
  }

  func testProjectScopeTreatsAWorktreeGitFileAsTheRoot() throws {
    try withFixture { fixture in
      let main = try fixture.makeRepository(name: "main")
      let worktree = fixture.root.appending(path: "worktree", directoryHint: .isDirectory)
      try fixture.makeDirectory(worktree.appending(path: "nested"))
      try Data("gitdir: \(main.path(percentEncoded: false)).git/worktrees/wt\n".utf8)
        .write(to: worktree.appending(path: ".git"))

      let executor = fixture.executor(currentDirectory: worktree.appending(path: "nested"))
      let payload = try executor.install(
        SkillsChangeRequest(skillIDs: ["prowl-cli"], targetIDs: ["agents"], scope: .project))
      guard case .install(let change) = payload else { return XCTFail("Expected install payload") }

      XCTAssertEqual(change.root, worktree.path(percentEncoded: false).trimmingTrailingPathSeparator())
      XCTAssertEqual(
        try Data(contentsOf: worktree.appending(path: ".git")),
        Data("gitdir: \(main.path(percentEncoded: false)).git/worktrees/wt\n".utf8)
      )
    }
  }

  func testExplicitProjectPathResolvesToTheContainingGitRoot() throws {
    try withFixture { fixture in
      let repo = try fixture.makeRepository(name: "repo")
      let nested = repo.appending(path: "src/deep", directoryHint: .isDirectory)
      try fixture.makeDirectory(nested)

      let payload = try fixture.executor.install(
        SkillsChangeRequest(
          skillIDs: ["prowl-cli"], targetIDs: ["codex"], scope: .project,
          projectPath: nested.path(percentEncoded: false)))
      guard case .install(let change) = payload else { return XCTFail("Expected install payload") }

      XCTAssertEqual(change.root, repo.path(percentEncoded: false).trimmingTrailingPathSeparator())
      XCTAssertEqual(
        change.results.map(\.path),
        [repo.appending(path: ".codex/skills/prowl-cli").path(percentEncoded: false)]
      )
      XCTAssertFalse(FileManager.default.fileExists(atPath: nested.appending(path: ".codex").path()))
    }
  }

  func testProjectScopeRefusesTargetParentsThatEscapeTheRepository() throws {
    try withFixture { fixture in
      let repo = try fixture.makeRepository(name: "repo")
      let external = fixture.root.appending(path: "external", directoryHint: .isDirectory)
      try fixture.makeDirectory(external)
      try FileManager.default.createSymbolicLink(at: repo.appending(path: ".agents"), withDestinationURL: external)
      try fixture.makeDirectory(repo.appending(path: ".claude"))

      assertExitError(code: CLIErrorCode.installConflict) {
        _ = try fixture.executor.install(
          SkillsChangeRequest(scope: .project, projectPath: repo.path(percentEncoded: false)))
      }

      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path(percentEncoded: false)), [])
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: repo.appending(path: ".claude/skills/prowl-cli").path()),
        "A boundary violation on one target leaves the others untouched"
      )
    }
  }

  func testProjectScopeRefusesSkillsDirectoriesThatEscapeTheRepositoryOnInstallAndUninstall() throws {
    try withFixture { fixture in
      let repo = try fixture.makeRepository(name: "repo")
      let external = fixture.root.appending(path: "external", directoryHint: .isDirectory)
      try fixture.makeDirectory(external)
      try fixture.makeDirectory(repo.appending(path: ".codex"))
      try FileManager.default.createSymbolicLink(
        at: repo.appending(path: ".codex/skills"), withDestinationURL: external)
      try FileManager.default.createSymbolicLink(
        atPath: external.appending(path: "prowl-cli").path(percentEncoded: false),
        withDestinationPath: fixture.skillDirectory("prowl-cli")
      )
      let request = SkillsChangeRequest(
        skillIDs: ["prowl-cli"], targetIDs: ["codex"], scope: .project,
        projectPath: repo.path(percentEncoded: false))

      assertExitError(code: CLIErrorCode.installConflict) { _ = try fixture.executor.install(request) }
      assertExitError(code: CLIErrorCode.installConflict) { _ = try fixture.executor.uninstall(request) }

      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(atPath: external.appending(path: "prowl-cli").path()),
        fixture.skillDirectory("prowl-cli"),
        "The external link is never replaced or removed"
      )
    }
  }

  func testProjectScopeAcceptsSymlinksThatStayInsideTheRepository() throws {
    try withFixture { fixture in
      let repo = try fixture.makeRepository(name: "repo")
      try fixture.makeDirectory(repo.appending(path: ".claude"))
      try FileManager.default.createSymbolicLink(
        atPath: repo.appending(path: ".agents").path(percentEncoded: false), withDestinationPath: ".claude")

      let payload = try fixture.executor.install(
        SkillsChangeRequest(
          skillIDs: ["prowl-cli"], targetIDs: ["agents"], scope: .project,
          projectPath: repo.path(percentEncoded: false)))
      guard case .install(let change) = payload else { return XCTFail("Expected install payload") }

      XCTAssertEqual(change.results.map(\.after), [.installed])
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(
          atPath: repo.appending(path: ".claude/skills/prowl-cli").path(percentEncoded: false)),
        fixture.skillDirectory("prowl-cli")
      )
    }
  }

  func testProjectScopeWithoutAGitRootOrWithABadPathFails() throws {
    try withFixture { fixture in
      let plain = fixture.root.appending(path: "plain", directoryHint: .isDirectory)
      try fixture.makeDirectory(plain)

      assertExitError(code: CLIErrorCode.pathNotFound) {
        _ = try fixture.executor(currentDirectory: plain).install(SkillsChangeRequest(scope: .project))
      }
      assertExitError(code: CLIErrorCode.pathNotFound) {
        _ = try fixture.executor.install(
          SkillsChangeRequest(scope: .project, projectPath: plain.path(percentEncoded: false)))
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: plain.appending(path: ".claude").path()))
      assertExitError(code: CLIErrorCode.pathNotFound) {
        _ = try fixture.executor.install(
          SkillsChangeRequest(scope: .project, projectPath: fixture.root.appending(path: "missing").path()))
      }
      let file = fixture.root.appending(path: "file")
      try Data().write(to: file)
      assertExitError(code: CLIErrorCode.pathNotDirectory) {
        _ = try fixture.executor.install(
          SkillsChangeRequest(scope: .project, projectPath: file.path(percentEncoded: false)))
      }
    }
  }

  func testProjectScopeBareInstallWithoutDetectedTargetsFails() throws {
    try withFixture { fixture in
      let repo = try fixture.makeRepository(name: "repo")

      assertExitError(code: CLIErrorCode.targetNotFound) {
        _ = try fixture.executor.install(
          SkillsChangeRequest(scope: .project, projectPath: repo.path(percentEncoded: false)))
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appending(path: ".claude").path()))
    }
  }

  // MARK: - Helpers

  private func assertExitError(
    code: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () throws -> Void
  ) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
      XCTAssertEqual((error as? ExitError)?.code, code, "\(error)", file: file, line: line)
    }
  }

  private struct Fixture {
    let root: URL
    let home: URL
    let skills: [BundledSkill]

    var executor: SkillsCommandExecutor {
      executor(currentDirectory: root)
    }

    func executor(currentDirectory: URL) -> SkillsCommandExecutor {
      SkillsCommandExecutor(skills: skills, userRoot: home, currentDirectory: currentDirectory)
    }

    func skillDirectory(_ id: String) -> String {
      root.appending(path: "skills/\(id)", directoryHint: .notDirectory).path(percentEncoded: false)
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

    func makeRepository(name: String) throws -> URL {
      let repo = root.appending(path: name, directoryHint: .isDirectory)
      try makeDirectory(repo.appending(path: ".git/info"))
      try Data("ref: refs/heads/main\n".utf8).write(to: repo.appending(path: ".git/HEAD"))
      return repo
    }

    func gitEntries(_ repo: URL) throws -> [String] {
      let enumerator = FileManager.default.enumerator(atPath: repo.appending(path: ".git").path(percentEncoded: false))
      var entries: [String] = []
      while let entry = enumerator?.nextObject() as? String {
        entries.append(entry)
      }
      return entries.sorted()
    }

    func isSymlink(_ path: String) -> Bool {
      (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
        == .typeSymbolicLink
    }
  }

  private func withFixture(_ operation: (Fixture) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-skills-executor-\(UUID().uuidString)", directoryHint: .isDirectory)
      .standardizedFileURL
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appending(path: "home", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home.appending(path: ".agents"), withIntermediateDirectories: true)

    let skillsRoot = root.appending(path: "skills", directoryHint: .isDirectory)
    try writeSkill(id: "prowl-cli", name: "Prowl CLI", audience: nil, skillsRoot: skillsRoot)
    try writeSkill(id: "reviewer", name: "Reviewer", audience: "workflow", skillsRoot: skillsRoot)
    let skills = try ProwlSkills.bundledForCLI(
      executableURL: root.appending(path: "prowl"),
      environment: ["PROWL_SKILLS_DIR": skillsRoot.path(percentEncoded: false)]
    )

    try operation(Fixture(root: root, home: home, skills: skills))
  }

  private func writeSkill(id: String, name: String, audience: String?, skillsRoot: URL) throws {
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
