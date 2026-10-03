import Foundation
import JSONSchema
import ProwlCLIContracts
import ProwlCLIShared
import XCTest

final class SkillsSchemaTests: XCTestCase {
  private let target =
    #"{"id":"claude","detected":true,"path":"/Users/me/.claude/skills/prowl-cli","status":"installed"}"#

  func testSchemaAcceptsEveryActionAndStatus() throws {
    let targets = [
      #"{"id":"claude","detected":false,"path":"/Users/me/.claude/skills/prowl-cli","status":"not_installed"}"#,
      #"{"id":"codex","detected":true,"path":"/Users/me/.codex/skills/prowl-cli","status":"installed"}"#,
      #"{"id":"agents","detected":true,"path":"/Users/me/.agents/skills/prowl-cli","status":"installed_different_source"}"#,
      #"{"id":"agents","detected":true,"path":"/Users/me/.agents/skills/prowl-cli","status":"installed_different_source","destination":"/DerivedData/Prowl.app/Contents/Resources/skills/prowl-cli"}"#,
      #"{"id":"codex","detected":true,"path":"/Users/me/.codex/skills/prowl-cli","status":"broken","destination":"/Volumes/Old/Prowl.app/Contents/Resources/skills/prowl-cli"}"#,
    ].joined(separator: ",")
    let list =
      #"{"ok":true,"command":"skills","schema_version":"prowl.cli.skills.v1","data":{"action":"list","skills":[{"id":"prowl-cli","name":"prowl-cli","description":"Drive Prowl.","audience":"user","path":"/Applications/Prowl.app/Contents/Resources/skills/prowl-cli","targets":[\#(targets)]}]}}"#
    let install =
      #"{"ok":true,"command":"skills","schema_version":"prowl.cli.skills.v1","data":{"action":"install","scope":"user","root":"/Users/me","results":[{"skill":"prowl-cli","target":"claude","path":"/Users/me/.claude/skills/prowl-cli","before":"broken","after":"installed"}]}}"#
    let uninstall =
      #"{"ok":true,"command":"skills","schema_version":"prowl.cli.skills.v1","data":{"action":"uninstall","scope":"project","root":"/Projects/App","results":[{"skill":"prowl-cli","target":"codex","path":"/Projects/App/.codex/skills/prowl-cli","before":"installed","after":"not_installed"}],"note":"Links carry absolute paths; consider .git/info/exclude."}}"#
    let path =
      #"{"ok":true,"command":"skills","schema_version":"prowl.cli.skills.v1","data":{"action":"path","skill":{"id":"reviewer","name":"Reviewer","audience":"workflow","path":"/Applications/Prowl.app/Contents/Resources/skills/reviewer"}}}"#
    let error =
      #"{"ok":false,"command":"skills","schema_version":"prowl.cli.skills.v1","error":{"code":"SKILL_NOT_INSTALLABLE","message":"reviewer is a workflow skill."}}"#

    for instance in [list, install, uninstall, path, error] {
      try assertValidity(instance, expected: true)
    }
  }

  func testSchemaRejectsUnknownFieldsInvalidStatusesAndCrossActionFields() throws {
    let unknownField =
      #"{"ok":true,"command":"skills","schema_version":"prowl.cli.skills.v1","data":{"action":"list","skills":[{"id":"prowl-cli","name":"prowl-cli","description":"Drive Prowl.","audience":"user","path":"/skills/prowl-cli","targets":[\#(target)],"extra":true}]}}"#
    let invalidStatus =
      #"{"ok":true,"command":"skills","schema_version":"prowl.cli.skills.v1","data":{"action":"install","scope":"user","root":"/Users/me","results":[{"skill":"prowl-cli","target":"claude","path":"/x","before":"missing","after":"installed"}]}}"#
    let crossAction =
      #"{"ok":true,"command":"skills","schema_version":"prowl.cli.skills.v1","data":{"action":"path","skill":{"id":"prowl-cli","name":"prowl-cli","audience":"user","path":"/x"},"results":[]}}"#
    let invalidAudience =
      #"{"ok":true,"command":"skills","schema_version":"prowl.cli.skills.v1","data":{"action":"path","skill":{"id":"prowl-cli","name":"prowl-cli","audience":"everyone","path":"/x"}}}"#
    let wrongVersion =
      #"{"ok":true,"command":"skills","schema_version":"prowl.cli.skills.v2","data":{"action":"list","skills":[]}}"#

    for instance in [unknownField, invalidStatus, crossAction, invalidAudience, wrongVersion] {
      try assertValidity(instance, expected: false)
    }
  }

  func testSchemaTiesDestinationToTheStatusesThatCanCarryIt() throws {
    func list(_ target: String) -> String {
      #"{"ok":true,"command":"skills","schema_version":"prowl.cli.skills.v1","data":{"action":"list","skills":[{"id":"prowl-cli","name":"prowl-cli","description":"Drive Prowl.","audience":"user","path":"/skills/prowl-cli","targets":[\#(target)]}]}}"#
    }
    let installedWithDestination = list(
      #"{"id":"claude","detected":true,"path":"/h/.claude/skills/prowl-cli","status":"installed","destination":"/x"}"#)
    let notInstalledWithDestination = list(
      #"{"id":"claude","detected":true,"path":"/h/.claude/skills/prowl-cli","status":"not_installed","destination":"/x"}"#)
    let brokenWithoutDestination = list(
      #"{"id":"claude","detected":true,"path":"/h/.claude/skills/prowl-cli","status":"broken"}"#)
    let emptyDestination = list(
      #"{"id":"claude","detected":true,"path":"/h/.claude/skills/prowl-cli","status":"broken","destination":""}"#)

    for instance in [installedWithDestination, notInstalledWithDestination, brokenWithoutDestination, emptyDestination] {
      try assertValidity(instance, expected: false)
    }
  }

  func testPayloadRoundTripsThroughCodable() throws {
    let listed = SkillsCommandPayload.list(
      SkillsListPayload(skills: [
        SkillsCommandSkill(
          id: "prowl-cli", name: "prowl-cli", description: "d", audience: .user, path: "/bundle/prowl-cli",
          targets: [
            SkillsCommandTargetStatus(id: "claude", detected: true, path: "/h/.claude/skills/prowl-cli", status: .installed),
            SkillsCommandTargetStatus(
              id: "codex", detected: true, path: "/h/.codex/skills/prowl-cli", status: .installedDifferentSource,
              destination: "/dd/skills/prowl-cli"),
          ])
      ]))
    let listedJSON = String(decoding: try JSONEncoder().encode(listed), as: UTF8.self)
    XCTAssertEqual(listedJSON.components(separatedBy: "\"destination\"").count - 1, 1, "destination is omitted when nil")
    XCTAssertEqual(try JSONDecoder().decode(SkillsCommandPayload.self, from: Data(listedJSON.utf8)), listed)

    let payload = SkillsCommandPayload.install(
      SkillsChangePayload(
        scope: .project,
        root: "/Projects/App",
        results: [
          SkillsCommandResult(
            skill: "prowl-cli", target: "claude", path: "/Projects/App/.claude/skills/prowl-cli",
            before: .notInstalled, after: .installed)
        ],
        note: "note"
      )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(payload)
    let text = String(decoding: data, as: UTF8.self)

    XCTAssertTrue(text.hasPrefix(#"{"action":"install""#))
    XCTAssertEqual(try JSONDecoder().decode(SkillsCommandPayload.self, from: data), payload)

    let listData = try encoder.encode(SkillsCommandPayload.list(SkillsListPayload(skills: [])))
    XCTAssertEqual(String(decoding: listData, as: UTF8.self), #"{"action":"list","skills":[]}"#)
    let response = CommandResponse(
      ok: true, command: "skills", schemaVersion: "prowl.cli.skills.v1",
      data: try RawJSON(encoding: SkillsCommandPayload.list(SkillsListPayload(skills: [])))
    )
    try assertValidity(String(decoding: try encoder.encode(response), as: UTF8.self), expected: true)
  }

  private func assertValidity(_ instance: String, expected: Bool) throws {
    let schemaText = try XCTUnwrap(String(data: ProwlCLIContractBundle.schemaData, encoding: .utf8))
    let result = try Schema(instance: schemaText).validate(instance: instance)
    XCTAssertEqual(result.isValid, expected, "Schema errors for \(instance): \(result.errors ?? [])")
  }
}
