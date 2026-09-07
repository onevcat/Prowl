// supacode/Domain/Workflow/WorkflowLineRenderer.swift
// The text a workflow run puts in front of an agent (docs-ai 063, dsl-spec §4/§10): the typed
// line formats, the single place that spells `prowl workflow deliver`, the launch protocol block,
// and the rendered-text boundary every typed line crosses.

import Foundation
import ProwlCLIShared

/// A rendered line would not survive as one terminal line (`RENDERED_TEXT_INVALID`).
nonisolated struct WorkflowRenderedTextError: Error, Equatable, Sendable {
  let line: String
  var code: String { CLIErrorCode.renderedTextInvalid }
  var message: String {
    "The rendered text contains a line terminator or control character and cannot be typed as one line."
  }
}

/// The rendered-text boundary: every string that reaches `insertCommittedText` + submit is
/// validated after template substitution, so a template value can never smuggle a newline
/// into a TUI. Violations stop the step; nothing is ever typed partially.
nonisolated enum WorkflowRenderedText {
  static func isSingleLine(_ text: String) -> Bool {
    WorkflowValidator.isSingleLine(text)
  }

  static func validateLine(_ line: String) throws(WorkflowRenderedTextError) {
    guard isSingleLine(line) else { throw WorkflowRenderedTextError(line: line) }
  }
}

/// The completion command of one activation. This is the only place that spells
/// `prowl workflow deliver`: the typed hint, the materialized instruction trailer, the launch
/// protocol block, the watchdog nudge, every re-delivery, and the `WORKFLOW_DELIVERY_REQUIRED`
/// message all read from it, so no path can show a token-less or verdict-less command.
nonisolated struct WorkflowCompletionCommand: Equatable, Sendable {
  static let protocolVersion = 1
  static let executable = "prowl workflow deliver"
  static let commandSeparator = "  or  "

  let token: String
  /// Declared verdict values; nil when the step has no verdict.
  let verdicts: [String]?

  init(token: String, verdicts: [String]?) {
    self.token = token
    self.verdicts = verdicts
  }

  /// `PROWL_WORKFLOW_TOKEN=<token> prowl workflow deliver [--verdict v] -`, one per allowed verdict.
  var messageCommands: [String] {
    launchCommands.map { "\(WorkflowSchema.tokenEnvironmentKey)=\(token) \($0)" }
  }

  /// `prowl workflow deliver [--verdict v] -`; the token travels in the launched child's environment.
  var launchCommands: [String] {
    guard let verdicts, !verdicts.isEmpty else { return ["\(Self.executable) -"] }
    return verdicts.map { "\(Self.executable) --verdict \($0) -" }
  }

  /// Appended to a typed `text` or pointer line.
  var typedSuffix: String {
    " — finish with: " + messageCommands.joined(separator: Self.commandSeparator)
  }

  /// The trailer of a materialized instruction file; lists the same commands as the typed line.
  func instructionTrailer() -> String {
    var lines = ["", "---", "When this step is fully complete, finish with"]
    if messageCommands.count > 1 {
      lines[lines.count - 1] += " exactly one of:"
    } else {
      lines[lines.count - 1] += ":"
    }
    lines += messageCommands.map { "    \($0)" }
    lines.append("")
    return lines.joined(separator: "\n")
  }

  /// The workflow protocol block appended to a `launch` step's kickoff prompt in place of S2's
  /// dispatch protocol. The token is not spelled: it is set in the child environment exactly
  /// like `PROWL_DISPATCH_ID`.
  func protocolBlock(
    runID: String,
    workflowName: String,
    role: String,
    stepTitle: String?,
    expect: WorkflowExpectation
  ) -> String {
    let (sections, format) = (expect.sections, expect.format)
    var lines = [
      "Prowl workflow completion protocol v\(Self.protocolVersion):",
      "You are the \"\(role)\" role of the Prowl workflow run \(runID) (\(workflowName)).",
    ]
    var delivery = "Deliver the output of this step"
    if let stepTitle, !stepTitle.isEmpty {
      delivery += " (\(stepTitle))"
    }
    delivery += " as \(Self.formatDescription(format)) on stdin"
    if !sections.isEmpty {
      delivery += " with the sections: \(sections.joined(separator: ", "))"
    }
    delivery += "."
    lines.append(delivery)
    if launchCommands.count > 1 {
      lines.append(
        "When your work for this step is fully complete, make exactly one of these commands your final tool action:")
    } else {
      lines.append("When your work for this step is fully complete, make this command your final tool action:")
    }
    for (index, command) in launchCommands.enumerated() {
      if index > 0 { lines.append("or:") }
      lines.append(command)
    }
    if launchCommands.count > 1 {
      lines.append("Choose exactly one verdict.")
    }
    lines.append(
      "Do not use prowl agents dispatch-complete for this step; Prowl supplies the workflow context automatically.")
    return lines.joined(separator: "\n") + "\n"
  }

  /// The `WORKFLOW_DELIVERY_REQUIRED` message for a `dispatch-complete` issued against this activation.
  func deliveryRequiredMessage(runID: String, stepID: String) -> String {
    "This pane's pending dispatch is a workflow activation (run \(runID), step \(stepID)); "
      + "deliver the step's output instead with: " + messageCommands.joined(separator: Self.commandSeparator)
  }

  private static func formatDescription(_ format: WorkflowDeliveryFormat) -> String {
    switch format {
    case .markdown: "a markdown document"
    case .text: "plain text"
    case .json: "a JSON document"
    }
  }
}

/// Typed line formats. Every line Prowl types into a pane starts with `[Prowl] ` so its origin
/// is visible; every line is validated as one terminal line before it is returned.
nonisolated enum WorkflowTypedLine {
  static let prefix = AgentDispatchPrompt.injectedPrefix
  static let nudgeText = "When your work for this step is fully complete, finish with: "

  /// `text` → `[Prowl] <text>[ — finish with: …]`.
  static func text(_ text: String, completion: WorkflowCompletionCommand?) throws(WorkflowRenderedTextError) -> String {
    try validated(prefix + text + (completion?.typedSuffix ?? ""))
  }

  /// `instruction` → `[Prowl] Read <absolute path> and follow it[ — finish with: …]`.
  static func pointer(to path: String, completion: WorkflowCompletionCommand?) throws(WorkflowRenderedTextError)
    -> String
  {
    try validated(prefix + "Read \(path) and follow it" + (completion?.typedSuffix ?? ""))
  }

  /// The panel's "Ask again" after a provisional delivery: what was missing, and the command.
  static func askAgain(
    issues: [WorkflowDeliveryIssue], completion: WorkflowCompletionCommand
  ) throws(WorkflowRenderedTextError) -> String {
    let problems = issues.map(\.message).joined(separator: "; ")
    return try validated(
      prefix + "Your delivery for this step had \(problems). Deliver it again, complete, with: "
        + completion.messageCommands.joined(separator: WorkflowCompletionCommand.commandSeparator))
  }

  /// The watchdog's one automatic nudge (and the panel's "Nudge again").
  static func nudge(completion: WorkflowCompletionCommand) throws(WorkflowRenderedTextError) -> String {
    try validated(
      prefix + nudgeText + completion.messageCommands.joined(separator: WorkflowCompletionCommand.commandSeparator))
  }

  private static func validated(_ line: String) throws(WorkflowRenderedTextError) -> String {
    try WorkflowRenderedText.validateLine(line)
    return line
  }
}

nonisolated enum WorkflowLaunchPromptError: Error, Equatable, Sendable {
  case containsNUL
  /// `PROMPT_TOO_LARGE`.
  case tooLarge(bytes: Int)

  var code: String {
    switch self {
    case .containsNUL: CLIErrorCode.invalidArgument
    case .tooLarge: CLIErrorCode.promptTooLarge
    }
  }
}

/// The kickoff prompt of a `launch` step: passed whole through A2's prompt carrier, so it may
/// span lines, but NUL is rejected and the rendered prompt is capped (dsl-spec §4).
nonisolated enum WorkflowLaunchPrompt {
  static let maximumBytes = WorkflowSizeLimits.launchPrompt

  static func validate(_ prompt: String) throws(WorkflowLaunchPromptError) {
    guard !prompt.contains("\0") else { throw .containsNUL }
    let bytes = prompt.utf8.count
    guard bytes <= maximumBytes else { throw .tooLarge(bytes: bytes) }
  }

  static func render(userPrompt: String, protocolBlock: String?) -> String {
    guard let protocolBlock else { return userPrompt }
    return "\(userPrompt)\n\n---\n\(protocolBlock)"
  }
}
