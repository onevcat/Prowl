import Foundation
import ProwlCLIShared
import XCTest

final class WorkflowDocumentParserTests: XCTestCase {
  // MARK: - The spec example

  func testExpectStrictParsesAndDefaultsToFalse() throws {
    let yaml = WorkflowFixtures.minimal(
      extraSteps: "  - id: a\n    message: author\n    text: x\n    expect: { delivery: a, strict: true }\n"
        + "  - id: b\n    message: author\n    text: y\n    expect: { delivery: b }")
    let workflow = try WorkflowFixtures.parse(yaml)
    XCTAssertEqual(workflow.steps[1].action.expect?.strict, true)
    XCTAssertEqual(workflow.steps[2].action.expect?.strict, false)
    XCTAssertEqual(
      WorkflowFixtures.codes(
        WorkflowFixtures.minimal(
          extraSteps: "  - id: a\n    message: author\n    text: x\n    expect: { strict: yes please }")),
      ["type_mismatch"])
  }

  func testParsesTheSpecExample() throws {
    let result = WorkflowDocumentParser.parse(WorkflowFixtures.adversarialReview)
    XCTAssertEqual(result.diagnostics, [])
    let workflow = try XCTUnwrap(result.definition)

    XCTAssertEqual(workflow.id, "prowl.adversarial-review")
    XCTAssertEqual(workflow.name, "Adversarial Review")
    XCTAssertEqual(workflow.description, "One reviewer, bounded rounds until clean.")
    XCTAssertEqual(workflow.icon, "magnifyingglass.circle")

    XCTAssertEqual(workflow.inputs.map(\.name), ["max_rounds", "focus", "mode"])
    XCTAssertEqual(workflow.inputs[0].type, .integer)
    XCTAssertEqual(workflow.inputs[0].defaultValue, .integer(5))
    XCTAssertEqual(workflow.inputs[0].minimum, 1)
    XCTAssertEqual(workflow.inputs[0].maximum, 10)
    XCTAssertEqual(workflow.inputs[1].type, .string)
    XCTAssertEqual(workflow.inputs[1].defaultValue, .string(""))
    XCTAssertEqual(workflow.inputs[1].prompt, "What should the reviewer focus on?")
    XCTAssertEqual(workflow.inputs[2].type, .enum)
    XCTAssertEqual(workflow.inputs[2].values, ["strict", "lenient"])
    XCTAssertEqual(workflow.inputs[2].defaultValue, .string("strict"))

    XCTAssertEqual(workflow.roles.map(\.name), ["author", "reviewer"])
    XCTAssertEqual(workflow.roles[0].source, .current)
    XCTAssertNil(workflow.roles[0].launch)
    let reviewer = try XCTUnwrap(workflow.roles[1].launch)
    XCTAssertEqual(reviewer.kind, .interactive)
    XCTAssertEqual(reviewer.agents, ["codex", "claude"])
    XCTAssertEqual(reviewer.suggest, WorkflowProfileSuggestion(agent: "codex", reasoningEffort: "xhigh", executionMode: "standard"))
    XCTAssertEqual(reviewer.bind, .ask)
    XCTAssertEqual(reviewer.placement, .split)
    XCTAssertEqual(reviewer.direction, .right)
    XCTAssertFalse(reviewer.background)

    XCTAssertEqual(workflow.steps.map(\.id), ["brief", "launch", "remember", "rounds", "context", "done", "cleanup"])
    XCTAssertEqual(workflow.flattenedSteps.map(\.id), ["brief", "launch", "remember", "rounds", "fix", "rereview", "retain", "context", "done", "cleanup"])

    guard case .message(let role, .instruction(let instruction), let briefExpect) = workflow.steps[0].action else {
      return XCTFail("brief should be an instruction message")
    }
    XCTAssertEqual(role, "author")
    XCTAssertTrue(instruction.hasPrefix("Write a short brief"))
    XCTAssertEqual(briefExpect?.delivery, "brief")
    XCTAssertEqual(briefExpect?.sections, ["## Scope", "## Claims"])
    XCTAssertEqual(briefExpect?.timeoutSeconds, 600)
    XCTAssertEqual(briefExpect?.format, .markdown)
    XCTAssertNil(briefExpect?.verdicts)
    XCTAssertEqual(workflow.steps[0].deliveryName, "brief")

    guard case .launch("reviewer", let prompt, "prowl.adversarial-reviewer", let launchExpect) = workflow.steps[1].action else {
      return XCTFail("launch should target reviewer with a skill")
    }
    XCTAssertTrue(prompt.contains("{{ deliveries.brief.path }}"))
    XCTAssertEqual(launchExpect?.verdicts, ["clean", "issues"])
    XCTAssertEqual(launchExpect?.timeoutSeconds, 1800)

    guard case .control(.loop(let condition, let maximum, let body)) = workflow.steps[3].action else {
      return XCTFail("rounds should be a while loop")
    }
    XCTAssertEqual(condition, "state.verdict != 'clean'")
    XCTAssertEqual(maximum, 10)
    XCTAssertEqual(body.map(\.id), ["fix", "rereview", "retain"])
    guard case .action("builtin:collect-worktree-context", let inputs) = workflow.steps[4].action else {
      return XCTFail("context should be a built-in action")
    }
    XCTAssertEqual(inputs, ["root": "{{ context.worktree.path }}"])
    XCTAssertEqual(workflow.steps[6].action, .close(role: "reviewer"))
  }

  func testStepLocationsAreOneBased() throws {
    let workflow = try WorkflowFixtures.parse(WorkflowFixtures.adversarialReview)
    XCTAssertEqual(workflow.steps[0].location, WorkflowSourceLocation(line: 33, column: 5))
    XCTAssertEqual(workflow.roles[1].location?.line, 16)
  }

  // MARK: - Structure

  func testUnknownKeysAreReportedWithTheirPosition() {
    let yaml = """
      schema: prowl.workflow/v1
      id: demo
      name: Demo
      bogus: 1
      steps:
        - id: a
          notify: hi
          expect: { delivery: x }
      """
    let diagnostics = WorkflowDocumentParser.parse(yaml).diagnostics
    XCTAssertEqual(diagnostics.map(\.code), ["unknown_key", "expect_not_allowed"])
    XCTAssertEqual(diagnostics[0].location, WorkflowSourceLocation(line: 4, column: 1))
    XCTAssertEqual(diagnostics[1].location, WorkflowSourceLocation(line: 8, column: 13))
  }

  func testMissingRequiredKeysAndUnsupportedSchema() {
    XCTAssertEqual(WorkflowFixtures.parseCodes("id: demo\nname: Demo\n"), ["missing_key", "missing_key"])
    XCTAssertEqual(
      WorkflowFixtures.parseCodes("schema: prowl.workflow/v99\nid: demo\nname: Demo\nsteps:\n  - id: a\n    notify: hi\n"),
      ["unsupported_schema"])
  }

  func testDocumentMustBeAMappingAndYamlSyntaxErrorsCarryAPosition() throws {
    XCTAssertEqual(WorkflowFixtures.parseCodes("- a\n- b\n"), ["document_not_mapping"])
    let syntax = WorkflowDocumentParser.parse("schema: prowl.workflow/v1\nsteps: [\n")
    XCTAssertEqual(syntax.diagnostics.map(\.code), ["yaml_syntax"])
    XCTAssertNotNil(try XCTUnwrap(syntax.diagnostics.first).location)
  }

  func testQuotedScalarsAreStringsAndPlainScalarsAreTyped() {
    let quoted = WorkflowFixtures.minimal()
      + "inputs:\n  n: { type: integer, default: \"5\" }\n"
    XCTAssertEqual(WorkflowFixtures.parseCodes(quoted), ["type_mismatch"])
    let quotedBool = WorkflowFixtures.minimal(extraRoles: "  r:\n    source: launch\n    background: \"true\"")
    XCTAssertEqual(WorkflowFixtures.parseCodes(quotedBool), ["type_mismatch"])
    let plain = WorkflowFixtures.minimal(extraRoles: "  r:\n    source: launch\n    background: true")
    XCTAssertEqual(WorkflowFixtures.parseCodes(plain), [])
  }

  func testInputKeysAreTypeSpecific() {
    let stringWithMin = WorkflowFixtures.minimal() + "inputs:\n  s: { type: string, min: 1 }\n"
    XCTAssertEqual(WorkflowFixtures.parseCodes(stringWithMin), ["key_requires_type"])
    let enumWithoutValues = WorkflowFixtures.minimal() + "inputs:\n  e: { type: enum }\n"
    XCTAssertEqual(WorkflowFixtures.parseCodes(enumWithoutValues), ["missing_key"])
    let unknownType = WorkflowFixtures.minimal() + "inputs:\n  e: { type: float }\n"
    XCTAssertEqual(WorkflowFixtures.parseCodes(unknownType), ["invalid_value"])
  }

  func testLaunchOnlyKeysAreRejectedOnOtherRoles() {
    let yaml = WorkflowFixtures.minimal(extraRoles: "  partner:\n    source: pick\n    placement: tab")
    XCTAssertEqual(WorkflowFixtures.parseCodes(yaml), ["key_requires_launch"])
  }

  func testHeadlessKindIsReservedAndTabPlacementIgnoresDirection() {
    let headless = WorkflowFixtures.minimal(extraRoles: "  r:\n    source: launch\n    kind: headless")
    let diagnostics = WorkflowDocumentParser.parse(headless).diagnostics
    XCTAssertEqual(diagnostics.map(\.code), ["reserved_kind"])
    XCTAssertTrue(diagnostics[0].message.contains("reserved"))
    let tab = WorkflowFixtures.minimal(extraRoles: "  r:\n    source: launch\n    placement: tab\n    direction: left")
    let tabDiagnostics = WorkflowDocumentParser.parse(tab).diagnostics
    XCTAssertEqual(tabDiagnostics.map(\.code), ["direction_ignored"])
    XCTAssertEqual(tabDiagnostics[0].severity, .warning)
  }

  // MARK: - Steps

  func testAStepNeedsExactlyOneVerb() {
    let none = WorkflowFixtures.minimal(extraSteps: "  - id: b\n    title: x")
    XCTAssertEqual(WorkflowFixtures.parseCodes(none), ["step_verb"])
    let two = WorkflowFixtures.minimal(extraSteps: "  - id: b\n    notify: x\n    close: author")
    XCTAssertEqual(WorkflowFixtures.parseCodes(two), ["step_verb"])
  }

  func testMessageNeedsExactlyOneOfTextOrInstruction() {
    let neither = WorkflowFixtures.minimal(extraSteps: "  - id: b\n    message: author")
    XCTAssertEqual(WorkflowFixtures.parseCodes(neither), ["message_content"])
    let both = WorkflowFixtures.minimal(extraSteps: "  - id: b\n    message: author\n    text: a\n    instruction: b")
    XCTAssertEqual(WorkflowFixtures.parseCodes(both), ["message_content"])
  }

  func testExpectIsRejectedOnActionNotifyAndClose() {
    for verb in ["action: git.context", "notify: hi", "close: author"] {
      let yaml = WorkflowFixtures.minimal(extraSteps: "  - id: b\n    \(verb)\n    expect: { delivery: o }")
      XCTAssertEqual(WorkflowFixtures.parseCodes(yaml), ["expect_not_allowed"], verb)
    }
  }



  func testDurationsAndOnTimeout() {
    XCTAssertEqual(WorkflowDocumentParser.parseDuration("90s"), 90)
    XCTAssertEqual(WorkflowDocumentParser.parseDuration("10m"), 600)
    XCTAssertEqual(WorkflowDocumentParser.parseDuration("2h"), 7200)
    XCTAssertNil(WorkflowDocumentParser.parseDuration("10"))
    XCTAssertNil(WorkflowDocumentParser.parseDuration("1d"))
    let badTimeout = WorkflowFixtures.minimal(
      extraSteps: "  - id: b\n    message: author\n    text: hi\n    expect: { timeout: 1d }")
    XCTAssertEqual(WorkflowFixtures.parseCodes(badTimeout), ["timeout_syntax"])
    let orphanPolicy = WorkflowFixtures.minimal(
      extraSteps: "  - id: b\n    message: author\n    text: hi\n    expect: { on_timeout: skip }")
    XCTAssertEqual(WorkflowFixtures.parseCodes(orphanPolicy), ["on_timeout_requires_timeout"])
  }

  func testActionInputsPreserveJSONTypes() throws {
    let yaml = WorkflowFixtures.minimal(
      extraSteps: "  - id: b\n    action: handoff.transition\n    with: { from: author, to: author, note: 42 }")
    let workflow = try WorkflowFixtures.parse(yaml)
    guard case .action("handoff.transition", let inputs) = workflow.steps[1].action else { return XCTFail("action") }
    XCTAssertEqual(inputs, ["from": .string("author"), "to": .string("author"), "note": .integer(42)])
    let nested = WorkflowFixtures.minimal(extraSteps: "  - id: b\n    action: git.context\n    with: { root: [a] }")
    XCTAssertEqual(WorkflowFixtures.parseCodes(nested), [])
  }

  // MARK: - Round 1 review findings

  func testHugeDurationsDoNotOverflow() {
    XCTAssertNil(WorkflowDocumentParser.parseDuration("9223372036854775807h"))
    XCTAssertNil(WorkflowDocumentParser.parseDuration("99999999999999999999s"))
    XCTAssertEqual(WorkflowDocumentParser.parseDuration("2562047788015215h"), 2562047788015215 * 3600)
    let overflow = WorkflowFixtures.minimal(
      extraSteps: "  - id: b\n    message: author\n    text: hi\n    expect: { timeout: 9223372036854775807h }")
    XCTAssertEqual(WorkflowFixtures.parseCodes(overflow), ["timeout_syntax"])
  }

  func testStepsMustNotBeEmpty() {
    XCTAssertEqual(
      WorkflowFixtures.parseCodes("schema: prowl.workflow/v1\nid: demo\nname: Demo\nsteps: []\n"), ["steps_empty"])
    let emptyBody = WorkflowFixtures.minimal(extraSteps: "  - id: loop\n    while: \"true\"\n    steps: []")
    XCTAssertEqual(WorkflowFixtures.parseCodes(emptyBody), ["steps_empty"])
  }

  func testStringFieldsRejectTypedPlainScalars() {
    XCTAssertEqual(
      WorkflowFixtures.parseCodes("schema: prowl.workflow/v1\nid: 1\nname: Demo\nsteps:\n  - id: a\n    notify: hi\n"),
      ["type_mismatch"])
    XCTAssertEqual(
      WorkflowFixtures.parseCodes("schema: prowl.workflow/v1\nid: demo\nname: 1.5\nsteps:\n  - id: a\n    notify: hi\n"),
      ["type_mismatch"])
    XCTAssertEqual(WorkflowFixtures.parseCodes(WorkflowFixtures.minimal(extraSteps: "  - id: b\n    notify: true")), ["type_mismatch"])
    XCTAssertEqual(WorkflowFixtures.parseCodes(WorkflowFixtures.minimal(extraSteps: "  - id: b\n    notify: \"true\"")), [])
    XCTAssertEqual(WorkflowFixtures.parseCodes(WorkflowFixtures.minimal(extraSteps: "  - id: b\n    notify: Round 1")), [])
  }

  func testUntilAndTimeoutFollowTheSchemaPatternsExactly() {
    XCTAssertNil(WorkflowDocumentParser.parseDuration(" 10m"))
    XCTAssertNil(WorkflowDocumentParser.parseDuration("10m "))
    let paddedTimeout = WorkflowFixtures.minimal(
      extraSteps: "  - id: b\n    message: author\n    text: hi\n    expect: { timeout: \" 10m\" }")
    XCTAssertEqual(WorkflowFixtures.parseCodes(paddedTimeout), ["timeout_syntax"])
    let legacy = WorkflowFixtures.minimal(extraSteps: "  - id: loop\n    repeat: {max: 2}\n    steps: [{id: x, notify: hi}]")
    XCTAssertEqual(WorkflowFixtures.parseCodes(legacy), ["step_verb"])
  }
}
