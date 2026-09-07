import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct WorkflowDeliveryValidatorTests {
  private let limits = WorkflowDeliveryLimits()

  private func validate(
    _ body: String,
    verdict: String? = nil,
    expect: WorkflowExpectation = WorkflowExpectation(),
    limits: WorkflowDeliveryLimits? = nil
  ) -> Result<WorkflowValidatedDelivery, WorkflowDeliveryError> {
    WorkflowDeliveryValidator.validate(body: body, verdict: verdict, expect: expect, limits: limits ?? self.limits)
  }

  @Test func markdownDeliveryIsNormalizedAndSectionsChecked() throws {
    let expect = WorkflowExpectation(sections: ["## Findings", "## Verdict"])
    let body = """
      Sure, here is my review:
      ```markdown
      # Review
      ## Findings
      - none
      ## Verdict
      clean
      ```
      Let me know if you need more.
      """
    let delivery = try validate(body, expect: expect).get()
    #expect(delivery.body == "# Review\n## Findings\n- none\n## Verdict\nclean\n")
    #expect(delivery.verdict == nil)
  }

  @Test func sectionsMustBeHeadingsOutsideCodeFences() throws {
    let expect = WorkflowExpectation(sections: ["## Findings", "## Verdict"], strict: true)
    let fenced = "# Review\n```text\n## Findings\n```\n## Verdict\nclean"
    guard case .failure(let error) = validate(fenced, expect: expect) else {
      Issue.record("a heading inside a fence must not count")
      return
    }
    #expect(error.message.contains("## Findings"))
    #expect(!error.message.contains("## Verdict"))
    let prose = "# Review\nsee ## Findings below\n## Verdict\nclean"
    #expect(validate(prose, expect: expect).failureCode == "OUTPUT_INVALID")
    let suffixed = "# Review\n## Findings (2)\n- a\n## Verdict\nclean"
    #expect(throws: Never.self) { try validate(suffixed, expect: expect).get() }
    #expect(validate("# Review\n## Findingsx\n## Verdict", expect: expect).failureCode == "OUTPUT_INVALID")
    let tilde = "# Review\n~~~\n## Findings\n~~~\n## Findings\n## Verdict\nok"
    #expect(throws: Never.self) { try validate(tilde, expect: expect).get() }
  }

  @Test func tildeWrappedRepliesPersistWithoutTheWrapper() throws {
    let expect = WorkflowExpectation(sections: ["## Findings", "## Verdict"])
    let delivery = try validate("~~~markdown\n## Findings\nx\n## Verdict\ny\n~~~\nchat trailer", expect: expect).get()
    #expect(delivery.body == "## Findings\nx\n## Verdict\ny\n")
  }

  @Test func missingSectionIsAnIssueByDefaultAndARejectionUnderStrict() throws {
    let lenient = WorkflowExpectation(sections: ["## Findings", "## Verdict"])
    let delivery = try validate("## Findings\nnothing", expect: lenient).get()
    #expect(delivery.issues == [.missingSections(["## Verdict"])])
    #expect(delivery.body == "## Findings\nnothing\n")

    let strict = WorkflowExpectation(sections: ["## Findings", "## Verdict"], strict: true)
    guard case .failure(let error) = validate("## Findings\nnothing", expect: strict) else {
      Issue.record("expected failure")
      return
    }
    #expect(error.code == "OUTPUT_INVALID")
    #expect(error.message.contains("## Verdict"))
  }

  @Test func sectionMatchingForgivesLevelAndCase() throws {
    let expect = WorkflowExpectation(sections: ["## Findings", "## Verdict"])
    let delivery = try validate("# Review\n### findings\n- a\n## VERDICT (draft)\nclean", expect: expect).get()
    #expect(delivery.issues.isEmpty)
  }

  @Test func softIssuesCoverFormatAndVerdict() throws {
    let json = try validate("{not json", expect: WorkflowExpectation(format: .json)).get()
    #expect(json.issues == [.unparsableJSON])
    #expect(json.body == "{not json")
    guard
      case .failure(let strictJSON) = validate("{not json", expect: WorkflowExpectation(format: .json, strict: true))
    else {
      Issue.record("expected failure")
      return
    }
    #expect(strictJSON.code == "OUTPUT_INVALID")

    let declared = WorkflowExpectation(verdicts: ["clean", "issues"])
    let missing = try validate("# ok\n", expect: declared).get()
    #expect(missing.issues == [.verdictMissing(allowed: ["clean", "issues"])])
    #expect(missing.verdict == nil)
    let undeclared = try validate("# ok\n", verdict: "maybe", expect: declared).get()
    #expect(undeclared.issues == [.verdictUndeclared("maybe", allowed: ["clean", "issues"])])
    #expect(undeclared.verdict == nil)
    let unexpected = try validate("# ok\n", verdict: "clean", expect: WorkflowExpectation()).get()
    #expect(unexpected.issues == [.verdictUnexpected("clean")])
    #expect(unexpected.verdict == nil)
    let clean = try validate("# ok\n", verdict: "issues", expect: declared).get()
    #expect(clean.issues.isEmpty)
    #expect(clean.verdict == "issues")
  }

  @Test func emptyBodyIsOutputInvalidForEveryFormat() {
    for format in [WorkflowDeliveryFormat.markdown, .text, .json] {
      guard case .failure(let error) = validate("  \n\n", expect: WorkflowExpectation(format: format)) else {
        Issue.record("expected failure for \(format)")
        continue
      }
      #expect(error.code == "OUTPUT_INVALID")
    }
  }

  @Test func textIsKeptVerbatimAndJSONMustParse() throws {
    let text = try validate("  raw text\nwith lines  ", expect: WorkflowExpectation(format: .text)).get()
    #expect(text.body == "  raw text\nwith lines  ")

    let json = try validate("{\"ok\": true}\n", expect: WorkflowExpectation(format: .json)).get()
    #expect(json.body == "{\"ok\": true}\n")
    guard case .failure(let error) = validate("{not json", expect: WorkflowExpectation(format: .json, strict: true))
    else {
      Issue.record("expected failure")
      return
    }
    #expect(error.code == "OUTPUT_INVALID")
  }

  @Test func verdictRulesFollowTheDeclarationUnderStrict() throws {
    let declared = WorkflowExpectation(verdicts: ["clean", "issues"], strict: true)
    guard case .failure(let required) = validate("# ok\n", expect: declared) else {
      Issue.record("expected VERDICT_REQUIRED")
      return
    }
    #expect(required == .verdictRequired(allowed: ["clean", "issues"]))
    #expect(required.code == "VERDICT_REQUIRED")

    guard case .failure(let undeclared) = validate("# ok\n", verdict: "maybe", expect: declared) else {
      Issue.record("expected OUTPUT_INVALID")
      return
    }
    #expect(undeclared.code == "OUTPUT_INVALID")

    let accepted = try validate("# ok\n", verdict: "issues", expect: declared).get()
    #expect(accepted.verdict == "issues")

    guard
      case .failure(let unexpected) = validate("# ok\n", verdict: "clean", expect: WorkflowExpectation(strict: true))
    else {
      Issue.record("expected OUTPUT_INVALID for an undeclared verdict")
      return
    }
    #expect(unexpected.code == "OUTPUT_INVALID")
  }

  @Test func sizeCapsUseTheDefaultAndClampToTheHardMaximum() {
    #expect(WorkflowDeliveryLimits.defaultMaximumBytes == 16 << 20)
    #expect(WorkflowDeliveryLimits.hardMaximumBytes == 16 << 20)
    #expect(WorkflowDeliveryLimits(maximumBytes: 32 << 20).maximumBytes == 16 << 20)
    #expect(WorkflowDeliveryLimits(maximumBytes: 0).maximumBytes == 1)

    let tooBig = "# a\n" + String(repeating: "x", count: 16 << 20)
    guard case .failure(let error) = validate(tooBig) else {
      Issue.record("expected OUTPUT_TOO_LARGE")
      return
    }
    #expect(error.code == "OUTPUT_TOO_LARGE")
    #expect(error == .outputTooLarge(bytes: tooBig.utf8.count, limit: 16 << 20))

    #expect(throws: Never.self) { try validate("# ok\n" + String(repeating: "x", count: (16 << 20) - 5)).get() }
  }

  @Test func sizeIsMeasuredOnTheRawBodyBeforeNormalization() {
    let expect = WorkflowExpectation(format: .markdown)
    let preamble = String(repeating: "p", count: (16 << 20) - 5)
    let body = preamble + "\n# ok\n"
    guard case .failure(let error) = validate(body, expect: expect) else {
      Issue.record("expected OUTPUT_TOO_LARGE")
      return
    }
    #expect(error.code == "OUTPUT_TOO_LARGE")
  }
}
