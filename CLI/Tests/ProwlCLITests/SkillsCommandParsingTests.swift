import ProwlCLIShared
import XCTest

@testable import prowl

final class SkillsCommandParsingTests: XCTestCase {
  func testRootRoutesSkillsLeaves() throws {
    XCTAssertTrue(try ProwlCommand.parseAsRoot(["skills", "list", "--json"]) is SkillsListCommand)
    XCTAssertTrue(try ProwlCommand.parseAsRoot(["skills", "install"]) is SkillsInstallCommand)
    XCTAssertTrue(try ProwlCommand.parseAsRoot(["skills", "uninstall", "prowl-cli"]) is SkillsUninstallCommand)
    XCTAssertTrue(try ProwlCommand.parseAsRoot(["skills", "path", "prowl-cli"]) is SkillsPathCommand)
  }

  func testInstallParsesRepeatedSkillsAndTargetsWithScopeAndPath() throws {
    let command = try SkillsInstallCommand.parse([
      "prowl-cli", "other", "--target", "claude", "--target", "codex", "--scope", "project", "--path", "/tmp/repo",
    ])

    XCTAssertEqual(
      try command.makeRequest(),
      SkillsChangeRequest(
        skillIDs: ["prowl-cli", "other"],
        targetIDs: ["claude", "codex"],
        scope: .project,
        projectPath: "/tmp/repo"
      )
    )
  }

  func testBareInstallAndUninstallDefaultToUserScope() throws {
    XCTAssertEqual(try SkillsInstallCommand.parse([]).makeRequest(), SkillsChangeRequest())
    XCTAssertEqual(try SkillsUninstallCommand.parse([]).makeRequest(), SkillsChangeRequest())
  }

  func testPathRequiresProjectScope() throws {
    let command = try SkillsUninstallCommand.parse(["--path", "/tmp/repo"])

    XCTAssertThrowsError(try command.makeRequest()) { error in
      XCTAssertEqual((error as? ExitError)?.code, CLIErrorCode.invalidArgument)
    }
  }

  func testRejectsInvalidScopeAndMissingValues() {
    XCTAssertThrowsError(try SkillsInstallCommand.parse(["--scope", "global"]))
    XCTAssertThrowsError(try SkillsInstallCommand.parse(["--target"]))
    XCTAssertThrowsError(try SkillsPathCommand.parse([]))
    XCTAssertThrowsError(try SkillsListCommand.parse(["prowl-cli"]))
  }
}
