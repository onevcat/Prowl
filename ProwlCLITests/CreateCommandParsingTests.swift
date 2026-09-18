import ProwlCLIShared
import XCTest

@testable import prowl

final class CreateCommandParsingTests: XCTestCase {
  func testTabAllowsBackgroundShellButSplitRequiresProfile() throws {
    let tab = try CreateTabCommand.parse(["App", "--background"])
    let input = try tab.makeInput()
    XCTAssertTrue(input.background)
    XCTAssertNil(input.launch)
    let pane = try CreatePaneCommand.parse(["p12", "--direction", "right", "--background"])
    XCTAssertThrowsError(try pane.makeInput())
  }

  func testPaneParsesPositionalAnchorAndDirection() throws {
    let command = try CreatePaneCommand.parse(["p12", "--direction", "up"])

    XCTAssertEqual(try command.makeInput().selector, .pane("p12"))
    XCTAssertEqual(try command.makeInput().direction, .upward)
  }

  func testPaneParsesTypedAnchorAndDirection() throws {
    let anchor = UUID().uuidString
    let command = try CreatePaneCommand.parse(["--pane", anchor, "--direction", "left"])

    XCTAssertEqual(try command.makeInput().selector, .pane(anchor))
    XCTAssertEqual(try command.makeInput().direction, .left)
  }

  func testPaneRequiresDirection() {
    XCTAssertThrowsError(try CreatePaneCommand.parse(["p12"]))
  }

  func testPaneRejectsNonPaneSelectors() throws {
    let worktree = try CreatePaneCommand.parse(["--worktree", "App", "--direction", "right"])
    let tab = try CreatePaneCommand.parse(["--tab", "t4", "--direction", "right"])

    XCTAssertThrowsError(try worktree.makeInput())
    XCTAssertThrowsError(try tab.makeInput())
    XCTAssertThrowsError(try CreatePaneCommand.parse(["--target", "p12", "--direction", "right"]))
  }

  func testPaneRejectsAmbiguousAndInvalidAnchors() throws {
    let mixed = try CreatePaneCommand.parse(["p12", "--pane", "p13", "--direction", "down"])
    let bareNumber = try CreatePaneCommand.parse(["12", "--direction", "down"])

    XCTAssertThrowsError(try mixed.makeInput())
    XCTAssertThrowsError(try bareNumber.makeInput())
  }

  func testTabParsesProfileLaunchAndBackground() throws {
    let command = try CreateTabCommand.parse(["App", "--profile", "Reviewer", "--background"])
    let input = try command.makeInput()

    XCTAssertEqual(input.launch, CreateLaunchInput(profile: "Reviewer"))
    XCTAssertTrue(input.background)
  }

  func testPaneParsesProfileLaunchAndBackground() throws {
    let command = try CreatePaneCommand.parse([
      "p12", "--direction", "right", "--profile", "Reviewer", "--background",
    ])
    let input = try command.makeInput()

    XCTAssertEqual(input.launch, CreateLaunchInput(profile: "Reviewer"))
    XCTAssertTrue(input.background)
  }

  func testPromptAcceptsOnlyTheStdinSentinel() throws {
    let inline = try CreateTabCommand.parse(["App", "--profile", "Reviewer", "--prompt", "inline"])

    XCTAssertThrowsError(try inline.makeInput())
  }

  func testPromptRejectsInteractiveStdinWithoutReading() {
    var options = CreateLaunchOptions()
    options.profile = "Reviewer"
    options.prompt = "-"
    var didRead = false

    XCTAssertThrowsError(
      try options.resolve(
        stdinIsTerminal: true,
        readStdin: {
          didRead = true
          return Data()
        }
      )
    ) { error in
      XCTAssertEqual((error as? ExitError)?.code, CLIErrorCode.invalidArgument)
    }
    XCTAssertFalse(didRead)
  }

  func testPromptRejectsOversizedUTF8Input() {
    var options = CreateLaunchOptions()
    options.profile = "Reviewer"
    options.prompt = "-"

    XCTAssertThrowsError(
      try options.resolve(
        stdinIsTerminal: false,
        readStdin: {
          Data(repeating: 0x78, count: CreateLaunchInput.maximumPromptUTF8ByteCount + 1)
        }
      )
    ) { error in
      XCTAssertEqual((error as? ExitError)?.code, CLIErrorCode.invalidArgument)
    }
  }

  func testPromptAndBackgroundRequireAProfile() throws {
    let prompt = try CreateTabCommand.parse(["App", "--prompt", "-"])
    let background = try CreatePaneCommand.parse(["p12", "--direction", "right", "--background"])

    XCTAssertThrowsError(try prompt.makeInput())
    XCTAssertThrowsError(try background.makeInput())
  }

  func testPromptedLaunchFailsClosedWhenOldAppOmitsDispatch() throws {
    let response = try makeCreateResponse(dispatch: nil)

    XCTAssertThrowsError(
      try CreateCommand.validateProfileLaunchResponse(
        response,
        requestedLaunch: CreateLaunchInput(profile: "Reviewer", prompt: "Review this")
      )
    ) { error in
      XCTAssertEqual((error as? ExitError)?.code, CLIErrorCode.createFailed)
    }
  }

  func testUnpromptedLaunchRemainsCompatibleAndPromptedLaunchAcceptsDispatch() throws {
    let legacyResponse = try makeCreateResponse(dispatch: nil)
    XCTAssertNoThrow(
      try CreateCommand.validateProfileLaunchResponse(
        legacyResponse,
        requestedLaunch: CreateLaunchInput(profile: "Reviewer")
      )
    )

    let modernResponse = try makeCreateResponse(
      dispatch: DispatchPendingRecord(id: "d1", createdAt: "2026-08-23T02:00:00.000Z")
    )
    XCTAssertNoThrow(
      try CreateCommand.validateProfileLaunchResponse(
        modernResponse,
        requestedLaunch: CreateLaunchInput(profile: "Reviewer", prompt: "Review this")
      )
    )
  }

  private func makeCreateResponse(dispatch: DispatchPendingRecord?) throws -> CommandResponse {
    let target = TabTarget(
      worktree: TabTargetWorktree(
        id: "wt", name: "main", path: "/Projects/Prowl", rootPath: "/Projects/Prowl", kind: "git"
      ),
      tab: TabTargetTab(id: "tab", title: "Tab", selected: true),
      pane: TabTargetPane(id: "pane", title: "Pane", cwd: "/Projects/Prowl", focused: true)
    )
    let launch = LifecycleCommandLaunch(
      profileID: UUID().uuidString,
      profileName: "Reviewer",
      agent: "codex"
    )
    return CommandResponse(
      ok: true,
      command: "create",
      schemaVersion: "prowl.cli.create.v1",
      data: try RawJSON(
        encoding: LifecycleCommandPayload(resource: .tab, launch: launch, dispatch: dispatch, target: target)
      )
    )
  }
}
