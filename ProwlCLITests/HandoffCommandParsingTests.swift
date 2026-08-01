import ProwlCLIShared
import Foundation
import XCTest

@testable import prowl

final class HandoffCommandParsingTests: XCTestCase {
  func testSaveAcceptsPositionalTarget() throws {
    let command = try HandoffSaveCommand.parse(["App"])

    XCTAssertEqual(
      try command.selector.resolve(positionalTarget: command.target),
      .auto("App")
    )
  }

  func testSaveRejectsPositionalTargetAlongsideFlagSelector() throws {
    let command = try HandoffSaveCommand.parse(["App", "--worktree", "Other"])

    XCTAssertThrowsError(try command.selector.resolve(positionalTarget: command.target))
  }

  func testSaveParsesBriefOptions() throws {
    let plain = try HandoffSaveCommand.parse(["App"])
    XCTAssertNil(plain.briefOptions.brief)
    XCTAssertFalse(plain.briefOptions.noBrief)

    let inline = try HandoffSaveCommand.parse(["App", "--brief", "# Handoff\ntext"])
    XCTAssertEqual(inline.briefOptions.brief, "# Handoff\ntext")

    let contextOnly = try HandoffSaveCommand.parse(["App", "--no-brief"])
    XCTAssertTrue(contextOnly.briefOptions.noBrief)
  }

  func testBriefAndNoBriefAreMutuallyExclusive() throws {
    let command = try HandoffSaveCommand.parse(["App", "--brief", "text", "--no-brief"])

    XCTAssertThrowsError(try command.briefOptions.resolve())
  }

  func testEmptyInlineBriefIsRejected() throws {
    let command = try HandoffSaveCommand.parse(["App", "--brief", "   "])

    XCTAssertThrowsError(try command.briefOptions.resolve())
  }

  func testInlineBriefValueResolvesVerbatim() throws {
    let command = try HandoffToCommand.parse(["claude", "--brief", "# Handoff\nbody"])

    let resolved = try command.briefOptions.resolve()
    XCTAssertEqual(resolved.brief, "# Handoff\nbody")
    XCTAssertFalse(resolved.contextOnly)
  }

  func testHUDRequestEnvironmentParsesOnlyValidUUID() {
    let requestID = UUID()
    let key = HandoffInput.requestIDEnvironmentKey

    XCTAssertEqual(HandoffRequestContext.requestID(in: [key: requestID.uuidString]), requestID)
    XCTAssertNil(HandoffRequestContext.requestID(in: [key: "not-a-uuid"]))
    XCTAssertNil(HandoffRequestContext.requestID(in: [:]))
  }

  func testToAcceptsPositionalTargetAfterAgent() throws {
    let command = try HandoffToCommand.parse(["claude", "App"])

    XCTAssertEqual(command.agent, "claude")
    XCTAssertEqual(
      try command.resolveReceivingTarget(),
      HandoffToCommand.ReceivingTarget(agent: "claude", profileID: nil)
    )
    XCTAssertEqual(
      try command.selector.resolve(positionalTarget: command.target),
      .auto("App")
    )
  }

  func testToParsesNoBriefAndNoLaunchFlags() throws {
    let command = try HandoffToCommand.parse(["claude", "App", "--no-brief", "--no-launch"])

    XCTAssertTrue(command.briefOptions.noBrief)
    XCTAssertTrue(command.noLaunch)
  }

  func testToAcceptsProfileWithoutSourceSelector() throws {
    let profileID = UUID()
    let command = try HandoffToCommand.parse(["--agent-profile-id", profileID.uuidString])

    XCTAssertNil(command.agent)
    XCTAssertNil(command.target)
    XCTAssertEqual(
      try command.resolveReceivingTarget(),
      HandoffToCommand.ReceivingTarget(agent: nil, profileID: profileID)
    )
    XCTAssertEqual(try command.selector.resolve(positionalTarget: command.target), .none)
  }

  func testToProfileAcceptsExplicitSelectorAndNoLaunch() throws {
    let profileID = UUID()
    let command = try HandoffToCommand.parse([
      "--agent-profile-id", profileID.uuidString,
      "--pane", "p1",
      "--no-launch",
    ])

    XCTAssertEqual(try command.selector.resolve(positionalTarget: command.target), .pane("p1"))
    XCTAssertTrue(command.noLaunch)
  }

  func testToRejectsMissingOrMultipleReceivingTargets() throws {
    let profileID = UUID().uuidString
    let missing = try HandoffToCommand.parse([])
    let multiple = try HandoffToCommand.parse(["codex", "--agent-profile-id", profileID])

    XCTAssertThrowsError(try missing.resolveReceivingTarget())
    XCTAssertThrowsError(try multiple.resolveReceivingTarget())
  }

  func testToProfileRejectsPositionalSource() throws {
    let command = try HandoffToCommand.parse(["App", "--agent-profile-id", UUID().uuidString])

    XCTAssertThrowsError(try command.resolveReceivingTarget())
  }

  func testToProfileRejectsMalformedUUID() throws {
    let command = try HandoffToCommand.parse(["--agent-profile-id", "not-a-uuid"])

    XCTAssertThrowsError(try command.resolveReceivingTarget())
  }
}
