// supacode/Domain/Workflow/WorkflowDeliveryValidator.swift
// Validation of a `prowl workflow deliver` body against the step's `expect` (dsl-spec §5): size
// caps, format, required sections, and the verdict declaration.

import Foundation
import ProwlCLIShared

nonisolated struct WorkflowDeliveryLimits: Equatable, Sendable {
  static let defaultMaximumBytes = WorkflowSizeLimits.payload
  static let hardMaximumBytes = WorkflowSizeLimits.payload

  /// Bytes of UTF-8 a delivered body may have; clamped to `1…hardMaximumBytes`.
  let maximumBytes: Int

  init(maximumBytes: Int = Self.defaultMaximumBytes) {
    self.maximumBytes = min(max(1, maximumBytes), Self.hardMaximumBytes)
  }
}

nonisolated enum WorkflowDeliveryError: Error, Equatable, Sendable {
  /// No activation is currently waiting for the caller (or for the addressed step).
  case stepNotExpecting
  case tokenRequired
  case tokenInvalid
  case outputInvalid(reason: String)
  case outputTooLarge(bytes: Int, limit: Int)
  case verdictRequired(allowed: [String])

  var code: String {
    switch self {
    case .stepNotExpecting: CLIErrorCode.stepNotExpecting
    case .tokenRequired: CLIErrorCode.tokenRequired
    case .tokenInvalid: CLIErrorCode.tokenInvalid
    case .outputInvalid: CLIErrorCode.outputInvalid
    case .outputTooLarge: CLIErrorCode.outputTooLarge
    case .verdictRequired: CLIErrorCode.verdictRequired
    }
  }

  var message: String {
    switch self {
    case .stepNotExpecting:
      "No workflow step is waiting for a delivery from this pane."
    case .tokenRequired:
      "The delivery token is missing; run the generated completion command "
        + "(\(WorkflowSchema.tokenEnvironmentKey)=… \(WorkflowCompletionCommand.executable) …)."
    case .tokenInvalid:
      "The delivery token does not belong to the step that is waiting; rerun the latest generated completion command."
    case .outputInvalid(let reason):
      "The delivered output is invalid: \(reason)"
    case .outputTooLarge(let bytes, let limit):
      "The delivered output is \(bytes) bytes; the limit is \(limit) bytes."
    case .verdictRequired(let allowed):
      "This step requires a verdict: pass --verdict with one of \(allowed.joined(separator: ", "))."
    }
  }
}

/// What a non-strict delivery got wrong (dsl-spec §5): the run keeps the output as provisional
/// and asks the user instead of bouncing the agent. Under `strict: true` the same findings are
/// rejections.
nonisolated enum WorkflowDeliveryIssue: Equatable, Sendable {
  case missingSections([String])
  case unparsableJSON
  case verdictMissing(allowed: [String])
  case verdictUndeclared(String, allowed: [String])
  case verdictUnexpected(String)

  var code: String {
    switch self {
    case .missingSections: "missing_sections"
    case .unparsableJSON: "unparsable_json"
    case .verdictMissing: "verdict_missing"
    case .verdictUndeclared: "verdict_undeclared"
    case .verdictUnexpected: "verdict_unexpected"
    }
  }

  var message: String {
    switch self {
    case .missingSections(let sections): "missing section(s) \(sections.joined(separator: ", "))"
    case .unparsableJSON: "the body is not parseable JSON"
    case .verdictMissing(let allowed): "no verdict (one of \(allowed.joined(separator: ", ")) is required)"
    case .verdictUndeclared(let value, let allowed):
      "verdict '\(value)' is not one of \(allowed.joined(separator: ", "))"
    case .verdictUnexpected(let value): "verdict '\(value)' was given but this step declares none"
    }
  }

  /// The rejection a strict step answers with.
  var rejection: WorkflowDeliveryError {
    switch self {
    case .verdictMissing(let allowed): .verdictRequired(allowed: allowed)
    default: .outputInvalid(reason: message + ".")
    }
  }
}

/// A delivery that passed validation: the body in its persisted form, the accepted verdict, and
/// the issues a non-strict step tolerated (empty when the delivery is clean).
nonisolated struct WorkflowValidatedDelivery: Equatable, Sendable {
  let body: String
  let verdict: String?
  let issues: [WorkflowDeliveryIssue]

  init(body: String, verdict: String?, issues: [WorkflowDeliveryIssue] = []) {
    self.body = body
    self.verdict = verdict
    self.issues = issues
  }
}

nonisolated enum WorkflowDeliveryValidator {
  /// Size and emptiness always reject; sections, format, and verdict reject only under
  /// `strict: true` and are otherwise returned as issues on an accepted delivery.
  static func validate(
    body: String,
    verdict: String?,
    expect: WorkflowExpectation,
    limits: WorkflowDeliveryLimits
  ) -> Result<WorkflowValidatedDelivery, WorkflowDeliveryError> {
    let bytes = body.utf8.count
    guard bytes <= limits.maximumBytes else {
      return .failure(.outputTooLarge(bytes: bytes, limit: limits.maximumBytes))
    }
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .failure(.outputInvalid(reason: "the body is empty."))
    }
    var issues: [WorkflowDeliveryIssue] = []
    var acceptedVerdict: String?
    switch (expect.verdicts, verdict) {
    case (nil, nil):
      break
    case (nil, .some(let value)):
      issues.append(.verdictUnexpected(value))
    case (.some(let allowed), nil):
      issues.append(.verdictMissing(allowed: allowed))
    case (.some(let allowed), .some(let value)):
      if allowed.contains(value) {
        acceptedVerdict = value
      } else {
        issues.append(.verdictUndeclared(value, allowed: allowed))
      }
    }
    var persisted = body
    switch expect.format {
    case .markdown:
      let normalized = MarkdownArtifactNormalizer.normalized(body)
      guard !normalized.isEmpty else {
        return .failure(.outputInvalid(reason: "the body is empty."))
      }
      let missing = MarkdownArtifactNormalizer.missingSections(expect.sections, in: normalized)
      if !missing.isEmpty {
        issues.append(.missingSections(missing))
      }
      persisted = normalized + "\n"
    case .text:
      break
    case .json:
      if (try? JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed])) == nil {
        issues.append(.unparsableJSON)
      }
    }
    if expect.strict, let first = issues.first {
      return .failure(first.rejection)
    }
    return .success(WorkflowValidatedDelivery(body: persisted, verdict: acceptedVerdict, issues: issues))
  }
}
