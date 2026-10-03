import Foundation
import ProwlCLIShared
import XCTest

final class ProwlSkillsTests: XCTestCase {
  func testBundledParsesPlainDescriptionAndDefaultsAudienceToUser() throws {
    try withTemporaryDirectory { root in
      let resources = root.appending(path: "Resources", directoryHint: .isDirectory)
      let skillDirectory = try writeSkill(
        id: "plain",
        frontmatter: """
          ---
          name: Plain Skill
          description: A plain description: with punctuation.
          ---
          """,
        resourcesURL: resources
      )

      let skills = try ProwlSkills.bundled(resourcesURL: resources)

      XCTAssertEqual(
        skills,
        [
          BundledSkill(
            id: "plain",
            name: "Plain Skill",
            description: "A plain description: with punctuation.",
            audience: .user,
            directoryURL: skillDirectory
          )
        ]
      )
    }
  }

  func testBundledParsesFoldedDescriptionAndAudienceMetadata() throws {
    try withTemporaryDirectory { root in
      let resources = root.appending(path: "Resources", directoryHint: .isDirectory)
      _ = try writeSkill(
        id: "reviewer",
        frontmatter: """
          ---
          name: Reviewer
          description: >-
            Review a proposed change and
            report actionable findings.

            Preserve paragraph boundaries.
          metadata:
            prowl-install: workflow
          ---
          """,
        resourcesURL: resources
      )

      let skill = try XCTUnwrap(ProwlSkills.bundled(resourcesURL: resources).first)

      XCTAssertEqual(
        skill.description,
        "Review a proposed change and report actionable findings.\nPreserve paragraph boundaries."
      )
      XCTAssertEqual(skill.audience, .workflow)
    }
  }

  func testBundledParsesOptionalSummaryMetadata() throws {
    try withTemporaryDirectory { root in
      let resources = root.appending(path: "Resources", directoryHint: .isDirectory)
      _ = try writeSkill(
        id: "summarized",
        frontmatter: """
          ---
          name: Summarized
          description: The long agent-facing description with every trigger phrase.
          metadata:
            prowl-summary: Short display text: what it does and how to use it.
            prowl-install: user
          ---
          """,
        resourcesURL: resources
      )
      _ = try writeSkill(
        id: "plain",
        frontmatter: """
          ---
          name: Plain
          description: No summary here.
          ---
          """,
        resourcesURL: resources
      )

      let skills = try ProwlSkills.bundled(resourcesURL: resources)

      XCTAssertEqual(skills.map(\.summary), [nil, "Short display text: what it does and how to use it."])
      XCTAssertEqual(skills.map(\.audience), [.user, .user])
    }
  }

  func testBundledRejectsEmptyOrDuplicateSummaryMetadata() throws {
    for metadata in ["  prowl-summary:", "  prowl-summary: One\n  prowl-summary: Two"] {
      try withTemporaryDirectory { root in
        let resources = root.appending(path: "Resources", directoryHint: .isDirectory)
        _ = try writeSkill(
          id: "bad",
          frontmatter: """
            ---
            name: Bad
            description: Valid description.
            metadata:
            \(metadata)
            ---
            """,
          resourcesURL: resources
        )

        XCTAssertThrowsError(try ProwlSkills.bundled(resourcesURL: resources)) { error in
          guard case ProwlSkillsError.invalidFrontmatter(_, let reason) = error else {
            return XCTFail("Expected invalidFrontmatter, got \(error)")
          }
          XCTAssertTrue(reason.contains("prowl-summary"), reason)
        }
      }
    }
  }

  func testBundledParsesExplicitUserAndWorkflowAudiences() throws {
    try withTemporaryDirectory { root in
      let resources = root.appending(path: "Resources", directoryHint: .isDirectory)
      _ = try writeSkill(
        id: "global",
        frontmatter: """
          ---
          name: Global
          description: Globally installable.
          metadata:
            prowl-install: user
          ---
          """,
        resourcesURL: resources
      )
      _ = try writeSkill(
        id: "workflow",
        frontmatter: """
          ---
          name: Workflow
          description: Workflow only.
          metadata:
            prowl-install: workflow
          ---
          """,
        resourcesURL: resources
      )

      let skills = try ProwlSkills.bundled(resourcesURL: resources)

      XCTAssertEqual(skills.map(\.audience), [.user, .workflow])
    }
  }

  func testBundledSortsSkillsByStableID() throws {
    try withTemporaryDirectory { root in
      let resources = root.appending(path: "Resources", directoryHint: .isDirectory)
      for id in ["zeta", "alpha", "middle"] {
        _ = try writeSkill(
          id: id,
          frontmatter: """
            ---
            name: \(id)
            description: \(id) description.
            ---
            """,
          resourcesURL: resources
        )
      }

      XCTAssertEqual(
        try ProwlSkills.bundled(resourcesURL: resources).map(\.id),
        ["alpha", "middle", "zeta"]
      )
    }
  }

  func testSkillLooksUpByIDAndReturnsNilForUnknownID() throws {
    try withTemporaryDirectory { root in
      let resources = root.appending(path: "Resources", directoryHint: .isDirectory)
      _ = try writeSkill(
        id: "prowl-cli",
        frontmatter: """
          ---
          name: Prowl CLI
          description: Control Prowl.
          ---
          """,
        resourcesURL: resources
      )

      XCTAssertEqual(
        try ProwlSkills.skill(id: "prowl-cli", resourcesURL: resources)?.name,
        "Prowl CLI"
      )
      XCTAssertNil(try ProwlSkills.skill(id: "missing", resourcesURL: resources))
      XCTAssertNil(try ProwlSkills.skill(id: "../prowl-cli", resourcesURL: resources))
    }
  }

  func testBundledRejectsMissingFrontmatter() throws {
    try withTemporaryDirectory { root in
      let resources = root.appending(path: "Resources", directoryHint: .isDirectory)
      _ = try writeSkill(
        id: "invalid",
        frontmatter: "# Missing frontmatter\n",
        resourcesURL: resources
      )

      XCTAssertThrowsError(try ProwlSkills.bundled(resourcesURL: resources)) { error in
        XCTAssertEqual((error as? ProwlSkillsError)?.code, .invalidFrontmatter)
      }
    }
  }

  func testBundledRejectsInvalidFrontmatter() throws {
    try withTemporaryDirectory { root in
      let resources = root.appending(path: "Resources", directoryHint: .isDirectory)
      _ = try writeSkill(
        id: "invalid",
        frontmatter: """
          ---
          name: Invalid
          description: Invalid audience.
          metadata:
            prowl-install: everywhere
          ---
          """,
        resourcesURL: resources
      )

      XCTAssertThrowsError(try ProwlSkills.bundled(resourcesURL: resources)) { error in
        guard let skillsError = error as? ProwlSkillsError,
          case .invalidFrontmatter(_, let reason) = skillsError
        else {
          return XCTFail("Expected invalid skill frontmatter")
        }
        XCTAssertEqual(reason, "metadata.prowl-install must be user or workflow")
      }
    }
  }

  func testBundledRejectsTopLevelProwlInstallMetadata() throws {
    try withTemporaryDirectory { root in
      let resources = root.appending(path: "Resources", directoryHint: .isDirectory)
      _ = try writeSkill(
        id: "invalid",
        frontmatter: """
          ---
          name: Invalid
          description: Invalid audience nesting.
          metadata:
          prowl-install: workflow
          ---
          """,
        resourcesURL: resources
      )

      XCTAssertThrowsError(try ProwlSkills.bundled(resourcesURL: resources)) { error in
        XCTAssertEqual((error as? ProwlSkillsError)?.code, .invalidFrontmatter)
      }
    }
  }

  func testBundledRejectsNestedProwlInstallMetadata() throws {
    try withTemporaryDirectory { root in
      let resources = root.appending(path: "Resources", directoryHint: .isDirectory)
      _ = try writeSkill(
        id: "invalid",
        frontmatter: """
          ---
          name: Invalid
          description: Invalid audience nesting.
          metadata:
            vendor:
              prowl-install: workflow
          ---
          """,
        resourcesURL: resources
      )

      XCTAssertThrowsError(try ProwlSkills.bundled(resourcesURL: resources)) { error in
        XCTAssertEqual((error as? ProwlSkillsError)?.code, .invalidFrontmatter)
      }
    }
  }

  func testBundledRejectsInconsistentlyIndentedMetadataFields() throws {
    try withTemporaryDirectory { root in
      let resources = root.appending(path: "Resources", directoryHint: .isDirectory)
      _ = try writeSkill(
        id: "invalid",
        frontmatter: """
          ---
          name: Invalid
          description: Invalid metadata indentation.
          metadata:
            vendor: scalar
              nested: value
          ---
          """,
        resourcesURL: resources
      )

      XCTAssertThrowsError(try ProwlSkills.bundled(resourcesURL: resources)) { error in
        XCTAssertEqual((error as? ProwlSkillsError)?.code, .invalidFrontmatter)
      }
    }
  }

  func testCLIOverrideTakesPrecedenceOverExecutableBundle() throws {
    try withTemporaryDirectory { root in
      let bundledResources = root.appending(
        path: "Prowl.app/Contents/Resources", directoryHint: .isDirectory)
      let executable = bundledResources.appending(
        path: "prowl-cli/prowl", directoryHint: .notDirectory)
      try writeFile("binary", to: executable)
      _ = try writeSkill(
        id: "bundled",
        frontmatter: validFrontmatter(name: "Bundled"),
        resourcesURL: bundledResources
      )

      let overrideSkills = root.appending(path: "override-skills", directoryHint: .isDirectory)
      _ = try writeSkill(
        id: "override",
        frontmatter: validFrontmatter(name: "Override"),
        skillsURL: overrideSkills
      )

      let skills = try ProwlSkills.bundledForCLI(
        executableURL: executable,
        environment: ["PROWL_SKILLS_DIR": overrideSkills.path(percentEncoded: false)]
      )

      XCTAssertEqual(skills.map(\.id), ["override"])
    }
  }

  func testCLIInvalidOverrideDoesNotFallBackToExecutableBundle() throws {
    try withTemporaryDirectory { root in
      let resources = root.appending(
        path: "Prowl.app/Contents/Resources", directoryHint: .isDirectory)
      let executable = resources.appending(path: "prowl-cli/prowl", directoryHint: .notDirectory)
      try writeFile("binary", to: executable)
      _ = try writeSkill(
        id: "bundled",
        frontmatter: validFrontmatter(name: "Bundled"),
        resourcesURL: resources
      )
      let missingOverride = root.appending(path: "missing-skills", directoryHint: .isDirectory)

      XCTAssertThrowsError(
        try ProwlSkills.bundledForCLI(
          executableURL: executable,
          environment: ["PROWL_SKILLS_DIR": missingOverride.path(percentEncoded: false)]
        )
      ) { error in
        XCTAssertEqual((error as? ProwlSkillsError)?.code, .bundleNotFound)
      }
    }
  }

  func testCLIResolvesBundleThroughExecutableSymlink() throws {
    try withTemporaryDirectory { root in
      let resources = root.appending(
        path: "Prowl.app/Contents/Resources", directoryHint: .isDirectory)
      let bundledExecutable = resources.appending(
        path: "prowl-cli/prowl", directoryHint: .notDirectory)
      try writeFile("binary", to: bundledExecutable)
      _ = try writeSkill(
        id: "prowl-cli",
        frontmatter: validFrontmatter(name: "Prowl CLI"),
        resourcesURL: resources
      )

      let executableSymlink = root.appending(path: "bin/prowl", directoryHint: .notDirectory)
      try FileManager.default.createDirectory(
        at: executableSymlink.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.createSymbolicLink(
        at: executableSymlink,
        withDestinationURL: bundledExecutable
      )

      let skills = try ProwlSkills.bundledForCLI(
        executableURL: executableSymlink,
        environment: [:]
      )

      XCTAssertEqual(skills.map(\.id), ["prowl-cli"])
      XCTAssertEqual(
        skills.first?.directoryURL,
        resources.appending(path: "skills/prowl-cli", directoryHint: .isDirectory)
      )
    }
  }

  func testCLIReturnsBundleNotFoundWhenNoBundleOrOverrideExists() throws {
    try withTemporaryDirectory { root in
      let executable = root.appending(path: "bin/prowl", directoryHint: .notDirectory)
      try writeFile("binary", to: executable)

      XCTAssertThrowsError(
        try ProwlSkills.bundledForCLI(executableURL: executable, environment: [:])
      ) { error in
        XCTAssertEqual((error as? ProwlSkillsError)?.code, .bundleNotFound)
      }
    }
  }

  private func withTemporaryDirectory(_ operation: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-skills-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try operation(root)
  }

  @discardableResult
  private func writeSkill(
    id: String,
    frontmatter: String,
    resourcesURL: URL
  ) throws -> URL {
    try writeSkill(
      id: id,
      frontmatter: frontmatter,
      skillsURL: resourcesURL.appending(path: "skills", directoryHint: .isDirectory)
    )
  }

  @discardableResult
  private func writeSkill(
    id: String,
    frontmatter: String,
    skillsURL: URL
  ) throws -> URL {
    let directory = skillsURL.appending(path: id, directoryHint: .isDirectory)
    try writeFile(
      frontmatter, to: directory.appending(path: "SKILL.md", directoryHint: .notDirectory))
    return directory
  }

  private func writeFile(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
  }

  private func validFrontmatter(name: String) -> String {
    """
    ---
    name: \(name)
    description: A bundled skill.
    ---
    """
  }
}
