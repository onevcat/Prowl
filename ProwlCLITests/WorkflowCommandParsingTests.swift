import ProwlCLIShared
import XCTest

@testable import prowl

final class WorkflowCommandParsingTests: XCTestCase {
  func testRootRoutesWorkflowSubcommands() throws {
    XCTAssertTrue(try ProwlCommand.parseAsRoot(["workflow", "list"]) is WorkflowListCommand)
    XCTAssertTrue(try ProwlCommand.parseAsRoot(["workflow", "run", "demo"]) is WorkflowRunCommand)
    XCTAssertTrue(try ProwlCommand.parseAsRoot(["workflow", "status"]) is WorkflowStatusCommand)
    XCTAssertTrue(try ProwlCommand.parseAsRoot(["workflow", "deliver", "-"]) is WorkflowDeliverCommand)
    XCTAssertTrue(
      try ProwlCommand.parseAsRoot(["workflow", "cancel", "00000000-0000-0000-0000-000000000000"])
        is WorkflowCancelCommand)
    XCTAssertTrue(
      try ProwlCommand.parseAsRoot(["workflow", "validate", "flow.yaml"]) is WorkflowValidateCommand
    )
    XCTAssertTrue(try ProwlCommand.parseAsRoot(["workflow", "schema"]) is WorkflowSchemaCommand)
  }

  func testListAcceptsAPositionalTargetOrOneSelectorFlag() throws {
    let bare = try WorkflowListCommand.parse(["--json"])
    XCTAssertEqual(try bare.selector.resolve(positionalTarget: bare.target), .none)

    let positional = try WorkflowListCommand.parse(["p3"])
    XCTAssertEqual(
      try positional.selector.resolve(positionalTarget: positional.target), .auto("p3"))

    let flag = try WorkflowListCommand.parse(["--worktree", "main"])
    XCTAssertEqual(try flag.selector.resolve(positionalTarget: flag.target), .worktree("main"))

    let both = try WorkflowListCommand.parse(["p3", "--worktree", "main"])
    XCTAssertThrowsError(try both.selector.resolve(positionalTarget: both.target)) { error in
      XCTAssertEqual((error as? ExitError)?.code, CLIErrorCode.invalidArgument)
    }
  }

  func testValidateRequiresAFileAndAcceptsAScope() throws {
    let command = try WorkflowValidateCommand.parse([
      "flows/review.yaml", "--scope", "repo", "--json",
    ])
    XCTAssertEqual(command.file, "flows/review.yaml")
    XCTAssertEqual(command.scope, .repo)
    XCTAssertTrue(command.options.json)
    XCTAssertNil(try WorkflowValidateCommand.parse(["x.yaml"]).scope)
    XCTAssertThrowsError(try WorkflowValidateCommand.parse([]))
    XCTAssertThrowsError(try WorkflowValidateCommand.parse(["x.yaml", "--scope", "global"]))
  }

  func testDoneParsesItsDeliveryOptions() throws {
    let deliver = try XCTUnwrap(
      ProwlCommand.parseAsRoot([
        "workflow", "deliver", "-", "--verdict", "clean", "--token", "T", "--run",
        "0BADCAFE-0000-4000-8000-000000000042", "--step", "review", "--force",
      ]) as? WorkflowDeliverCommand)
    XCTAssertEqual(deliver.input, "-")
    XCTAssertEqual(deliver.verdict, "clean")
    XCTAssertEqual(deliver.token, "T")
    XCTAssertEqual(deliver.runID, "0BADCAFE-0000-4000-8000-000000000042")
    XCTAssertEqual(deliver.step, "review")
    XCTAssertTrue(deliver.force)
    let file = try XCTUnwrap(
      ProwlCommand.parseAsRoot(["workflow", "deliver", "--file", "/tmp/out.md"])
        as? WorkflowDeliverCommand)
    XCTAssertEqual(file.file, "/tmp/out.md")
    XCTAssertNil(file.input)
  }

  func testDoneRejectsMissingOrDoubledBodiesAndHalfManualTargets() {
    XCTAssertThrowsError(try ProwlCommand.parseAsRoot(["workflow", "deliver"]))
    XCTAssertThrowsError(
      try ProwlCommand.parseAsRoot(["workflow", "deliver", "-", "--file", "/tmp/out.md"]))
    XCTAssertThrowsError(try ProwlCommand.parseAsRoot(["workflow", "deliver", "out.md"]))
    XCTAssertThrowsError(try ProwlCommand.parseAsRoot(["workflow", "deliver", "-", "--run", "id"]))
    XCTAssertThrowsError(try ProwlCommand.parseAsRoot(["workflow", "deliver", "-", "--step", "s"]))
    XCTAssertThrowsError(try ProwlCommand.parseAsRoot(["workflow", "deliver", "-", "--force"]))
    XCTAssertNoThrow(
      try ProwlCommand.parseAsRoot([
        "workflow", "deliver", "-", "--run", "id", "--step", "s", "--force",
      ]))
  }

  func testRunParsesRepeatableBindingsInputsAndSkips() throws {
    let run = try XCTUnwrap(
      ProwlCommand.parseAsRoot([
        "workflow", "run", "prowl.adversarial-review", "p3", "--role", "reviewer=Codex", "--role",
        "partner=p5",
        "--input", "max_rounds=3", "--skip", "brief",
      ]) as? WorkflowRunCommand)
    XCTAssertEqual(run.workflow, "prowl.adversarial-review")
    XCTAssertEqual(run.source, "p3")
    XCTAssertEqual(run.role, ["reviewer=Codex", "partner=p5"])
    XCTAssertEqual(run.input, ["max_rounds=3"])
    XCTAssertEqual(run.skip, ["brief"])
  }

  func testWorkflowDeliverEnvelopeCarriesTheBodyAndToken() throws {
    let envelope = CommandEnvelope(
      output: .json,
      command: .workflow(
        WorkflowInput(
          action: .deliver, runID: "r", stepID: "s", body: "# Out\n", verdict: "clean", token: "T",
          force: true)))
    let decoded = try JSONDecoder().decode(
      CommandEnvelope.self, from: try JSONEncoder().encode(envelope))
    guard case .workflow(let input) = decoded.command else {
      return XCTFail("Expected a workflow envelope")
    }
    XCTAssertEqual(input.action, .deliver)
    XCTAssertEqual(input.body, "# Out\n")
    XCTAssertEqual(input.token, "T")
    XCTAssertEqual(input.runID, "r")
    XCTAssertEqual(input.stepID, "s")
    XCTAssertTrue(input.force)
  }

  func testWorkflowInputEnvelopeEncodesTheTarget() throws {
    let envelope = CommandEnvelope(
      output: .json,
      command: .workflow(
        WorkflowInput(
          action: .run, target: .auto("p3"), workflow: "demo", roleBindings: ["reviewer=Codex"],
          inputValues: ["rounds=3"], skippedSteps: ["brief"])))
    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: data)
    guard case .workflow(let input) = decoded.command else {
      return XCTFail("Expected a workflow envelope")
    }
    XCTAssertEqual(input.action, .run)
    XCTAssertEqual(input.target, .auto("p3"))
    XCTAssertEqual(input.workflow, "demo")
    XCTAssertEqual(input.roleBindings, ["reviewer=Codex"])
    XCTAssertEqual(input.inputValues, ["rounds=3"])
    XCTAssertEqual(input.skippedSteps, ["brief"])
    XCTAssertEqual(decoded.command.name, "workflow")
  }
}
