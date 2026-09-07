// ProwlShared/WorkflowValidator.swift
// Semantic rules of dsl-spec.md §7 over a parsed WorkflowDefinition: references, control flow,
// slugs, verdicts, templates. Structural rules (keys, types) are the parser's.

import Foundation

nonisolated public enum WorkflowScope: String, Codable, Equatable, Sendable, CaseIterable {
  case bundle
  case user
  case repo
}

nonisolated public struct WorkflowValidationContext: Sendable {
  public let scope: WorkflowScope
  /// nil = the bundle is unavailable; `skill:` references are reported as unchecked warnings.
  public let bundledSkillIDs: Set<String>?
  /// The agent token catalog; nil = unknown tokens are not reported.
  public let knownAgents: Set<String>?
  /// Agents installed locally; nil = the "nothing installed" warning is skipped.
  public let installedAgents: Set<String>?
  /// Preset fields of the enabled Agent Profiles; nil = the `suggest` match warning is skipped.
  public let enabledProfiles: [WorkflowProfileSuggestion]?
  public let actions: [WorkflowActionSchema]
  public var localActions: [String: WorkflowScriptAction] = [:]

  public init(
    scope: WorkflowScope,
    bundledSkillIDs: Set<String>? = nil,
    knownAgents: Set<String>? = nil,
    installedAgents: Set<String>? = nil,
    enabledProfiles: [WorkflowProfileSuggestion]? = nil,
    actions: [WorkflowActionSchema] = WorkflowActionRegistry.all
  ) {
    self.scope = scope
    self.bundledSkillIDs = bundledSkillIDs
    self.knownAgents = knownAgents
    self.installedAgents = installedAgents
    self.enabledProfiles = enabledProfiles
    self.actions = actions
  }
}

nonisolated public enum WorkflowValidator {
  public static let completionCommand = "prowl workflow deliver"
  public static let longTimeoutSeconds = 2 * 3600

  public static func validate(
    _ definition: WorkflowDefinition, context: WorkflowValidationContext
  ) -> [WorkflowDiagnostic] {
    let walker = Walker(definition: definition, context: context)
    walker.run()
    return walker.collector.diagnostics
  }

  public static func isSingleLine(_ text: String) -> Bool {
    !text.unicodeScalars.contains { scalar in
      scalar == "\u{2028}" || scalar == "\u{2029}" || scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }
  }
}

// MARK: - Walker

nonisolated private enum OutputConsumer {
  case template
  case until
  case requiredActionInput
  case optionalActionInput
}

/// Where an output is read or skipped: the step's walk ordinal and the loop body it sits in.
nonisolated private struct OutputUse {
  let consumer: OutputConsumer
  let ordinal: Int
  let loopID: String?
}

nonisolated private struct SkipRecord {
  let name: String
  let use: OutputUse
  let location: WorkflowSourceLocation?
}

nonisolated private struct OutputProducer {
  let verdicts: Set<String>?
  /// The `repeat` step whose body holds the producer; nil at the top level.
  let loopID: String?
}

nonisolated private struct OutputInfo {
  var producers: [OutputProducer] = []
  /// Verdict set of the producer whose delivery is the latest at this point of the walk; nil
  /// when it declares none, or when a skippable loop leaves the latest producer ambiguous.
  var latestVerdicts: Set<String>?
}

nonisolated private final class Walker {
  let definition: WorkflowDefinition
  let context: WorkflowValidationContext
  let collector = DiagnosticCollector()

  private var stepIDs: Set<String> = []
  private var launchedRoles: Set<String> = []
  private var possiblyLaunchedRoles: Set<String> = []
  private var deliveries: [String: OutputInfo] = [:]
  private var consumers: [String: [OutputUse]] = [:]
  /// Walk position of the step being checked; 0 before the first step.
  private var ordinal = 0
  /// Action steps visible to the step being validated: outer sequences first, current last.
  private var actionScopes: [[String: WorkflowActionSchema]] = [[:]]
  private var checkingActionInputs = false
  private var currentLoopID: String?
  private var outerOutputNames: Set<String> = []
  /// `on_timeout: skip` expectations, kept apart from `deliveries` so folding a skippable loop
  /// cannot lose them before the consumers are reported.
  private var skipOutputs: [SkipRecord] = []

  init(definition: WorkflowDefinition, context: WorkflowValidationContext) {
    self.definition = definition
    self.context = context
  }

  func run() {
    checkHeader()
    definition.inputs.forEach(checkInput)
    checkRoles()
    definition.steps.forEach(checkStep)
    reportSkipConsumers()
  }

  // MARK: Header, inputs, roles

  private func checkHeader() {
    if definition.name.trimmingCharacters(in: .whitespaces).isEmpty {
      collector.error("name_empty", "'name' must not be blank.")
    }
    if !WorkflowSchema.isWorkflowID(definition.id) {
      collector.error("workflow_id", "Workflow id '\(definition.id)' is not a valid id (lowercase slug, max 64).")
    }
    if context.scope != .bundle, definition.id.hasPrefix(WorkflowSchema.reservedIDPrefix) {
      collector.error(
        "reserved_id", "Ids starting with '\(WorkflowSchema.reservedIDPrefix)' are reserved for bundled workflows.")
    }
  }

  private func checkInput(_ input: WorkflowInputDefinition) {
    if !WorkflowSchema.isSlug(input.name) {
      collector.error("input_name_slug", "Input name '\(input.name)' is not a valid slug.", at: input.location)
    }
    switch input.type {
    case .integer:
      if let minimum = input.minimum, let maximum = input.maximum, minimum > maximum {
        collector.error("input_range", "Input '\(input.name)' has min above max.", at: input.location)
      }
      if case .integer(let value)? = input.defaultValue,
        (input.minimum.map { value < $0 } ?? false) || (input.maximum.map { value > $0 } ?? false)
      {
        collector.error("input_range", "Input '\(input.name)' default lies outside min…max.", at: input.location)
      }
    case .string:
      if case .string(let value)? = input.defaultValue, !WorkflowValidator.isSingleLine(value) {
        collector.error(
          "input_default_multiline",
          "String input '\(input.name)' default must be one line without control characters.",
          at: input.location)
      }
    case .enum:
      if input.values.isEmpty {
        collector.error("enum_values_empty", "Enum input '\(input.name)' needs at least one value.", at: input.location)
      }
      if input.values.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
        collector.error("enum_value_empty", "Enum input '\(input.name)' lists an empty value.", at: input.location)
      }
      if Set(input.values).count != input.values.count {
        collector.error("enum_values_duplicate", "Enum input '\(input.name)' repeats a value.", at: input.location)
      }
      if input.values.contains(where: { !WorkflowValidator.isSingleLine($0) }) {
        collector.error(
          "enum_value_multiline",
          "Enum input '\(input.name)' values must be one line without control characters.",
          at: input.location)
      }
      if case .string(let value)? = input.defaultValue, !input.values.contains(value) {
        collector.error(
          "enum_default", "Enum input '\(input.name)' default '\(value)' is not one of its values.", at: input.location)
      }
    }
  }

  private func checkRoles() {
    let currentRoles = definition.roles.filter { $0.source == .current }
    if currentRoles.count > 1 {
      collector.error(
        "multiple_current_roles", "At most one role may use 'source: current'.", at: currentRoles[1].location)
    }
    for role in definition.roles {
      if !WorkflowSchema.isSlug(role.name) {
        collector.error("role_name_slug", "Role name '\(role.name)' is not a valid slug.", at: role.location)
      }
      guard let launch = role.launch else { continue }
      if (launch.agents ?? []).contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
        collector.error("agent_token_empty", "Role '\(role.name)' lists an empty agent token.", at: role.location)
      }
      checkAgentTokens(launch.agents ?? [], role: role)
      if let suggested = launch.suggest?.agent {
        checkAgentTokens([suggested], role: role)
      }
      if let agents = launch.agents, let installed = context.installedAgents, !agents.isEmpty,
        Set(agents).isDisjoint(with: installed)
      {
        collector.warning(
          "agents_not_installed",
          "No installed agent satisfies role '\(role.name)' (\(agents.joined(separator: ", "))).",
          at: role.location)
      }
      if let suggest = launch.suggest, let profiles = context.enabledProfiles,
        !profiles.contains(where: { Self.profile($0, matches: suggest) })
      {
        collector.warning(
          "suggest_unmatched", "No enabled Agent Profile matches the suggestion for role '\(role.name)'.",
          at: role.location)
      }
    }
  }

  /// Every field the suggestion names must equal the profile's; absent fields do not constrain.
  private static func profile(
    _ profile: WorkflowProfileSuggestion, matches suggest: WorkflowProfileSuggestion
  ) -> Bool {
    for (wanted, actual) in [
      (suggest.agent, profile.agent), (suggest.model, profile.model),
      (suggest.reasoningEffort, profile.reasoningEffort), (suggest.executionMode, profile.executionMode),
    ] where wanted != nil && wanted != actual {
      return false
    }
    return true
  }

  private func checkAgentTokens(_ tokens: [String], role: WorkflowRoleDefinition) {
    guard let known = context.knownAgents else { return }
    for token in tokens where !known.contains(token) {
      collector.warning(
        "unknown_agent", "Role '\(role.name)' names an unknown agent token '\(token)'.", at: role.location)
    }
  }

  // MARK: Steps

  private func checkStep(_ step: WorkflowStepDefinition) {
    ordinal += 1
    if !WorkflowSchema.isSlug(step.id) {
      collector.error("step_id_slug", "Step id '\(step.id)' is not a valid slug.", at: step.location)
    }
    if !stepIDs.insert(step.id).inserted {
      collector.error("duplicate_step_id", "Step id '\(step.id)' is used more than once.", at: step.location)
    }
    if let title = step.title {
      checkTemplate(title, at: step.location, consumer: .template)
    }
    switch step.action {
    case .message(let role, let content, let expect):
      checkMessage(step, role: role, content: content, expect: expect)
    case .launch(let role, let prompt, let skill, let expect):
      checkLaunch(step, role: role, prompt: prompt, skill: skill, expect: expect)
    case .action(let id, let inputs):
      checkAction(step, id: id, inputs: inputs)
    case .notify(let text):
      checkTemplate(text, at: step.location, consumer: .template)
    case .close(let role):
      if let definitionRole = requireRole(role, at: step.location), definitionRole.source != .launch {
        collector.error("close_role_source", "'close' applies to launch roles only.", at: step.location)
      }
    case .control(let control):
      checkControl(step, control: control)
    }
  }

  private func checkMessage(
    _ step: WorkflowStepDefinition, role: String, content: WorkflowMessageContent, expect: WorkflowExpectation?
  ) {
    if let definitionRole = requireRole(role, at: step.location), definitionRole.source == .launch,
      !launchedRoles.contains(role)
    {
      collector.error(
        "message_before_launch", "Step '\(step.id)' messages launch role '\(role)' before its launch step.",
        at: step.location)
    }
    if case .text(let text) = content, !WorkflowValidator.isSingleLine(text) {
      collector.error(
        "text_multiline", "'text' must be one line; use 'instruction' for multi-line content.", at: step.location)
    }
    checkTemplate(content.body, at: step.location, consumer: .template)
    warnIfSpellingCompletion(content.body, at: step.location)
    checkExpect(expect, step: step)
  }

  private func checkLaunch(
    _ step: WorkflowStepDefinition, role: String, prompt: String, skill: String?, expect: WorkflowExpectation?
  ) {
    if let definitionRole = requireRole(role, at: step.location) {
      if definitionRole.source != .launch {
        collector.error("launch_role_source", "'launch' applies to launch roles only.", at: step.location)
      } else if possiblyLaunchedRoles.contains(role) {
        collector.error("launch_twice", "Launch role '\(role)' is launched more than once.", at: step.location)
      }
    }
    checkTemplate(prompt, at: step.location, consumer: .template)
    warnIfSpellingCompletion(prompt, at: step.location)
    if let skill {
      checkSkill(skill, at: step.location)
    }
    checkExpect(expect, step: step)
    launchedRoles.insert(role)
    possiblyLaunchedRoles.insert(role)
  }

  private func checkSkill(_ skill: String, at location: WorkflowSourceLocation?) {
    guard WorkflowSchema.isWorkflowID(skill) else {
      collector.error("skill_id", "Skill id '\(skill)' is not a valid id.", at: location)
      return
    }
    guard let bundled = context.bundledSkillIDs else {
      collector.warning(
        "skill_unchecked", "Skill '\(skill)' was not checked: the app bundle is unavailable.", at: location)
      return
    }
    if !bundled.contains(skill) {
      collector.error("skill_not_found", "Skill '\(skill)' is not a bundled skill.", at: location)
    }
  }

  private func checkAction(_ step: WorkflowStepDefinition, id: String, inputs: [String: WorkflowJSONValue]) {
    checkingActionInputs = true
    defer { checkingActionInputs = false }
    for value in inputs.values { checkJSONTemplates(value, at: step.location) }
    if id.hasPrefix("local:") {
      let name = String(id.dropFirst(6))
      guard let contract = context.localActions[name] else {
        collector.error("unknown_action", "Bundle has no action '\(id)'.", at: step.location)
        return
      }
      var fields = WorkflowJSONValue.object([:])
      if case .object(var object) = fields {
        for (key, value) in inputs { object[key] = value }
        fields = .object(object)
      }
      if !String(describing: fields).contains("{{") {
        do { try contract.validateInput(fields) } catch {
          collector.error("action_input_schema", "\(error)", at: step.location)
        }
      }
      actionScopes[actionScopes.count - 1][step.id] = WorkflowActionSchema(
        id: id, description: contract.name, inputs: [],
        outputs: [
          WorkflowActionOutput(name: "output", description: "Typed action output"),
          WorkflowActionOutput(name: "output_path", description: "Result JSON path"),
        ])
      return
    }
    guard let schema = WorkflowActionRegistry.schema(for: id, in: context.actions) else {
      collector.error("unknown_action", "Unknown action '\(id)'.", at: step.location)
      return
    }
    for (key, value) in inputs.sorted(by: { $0.key < $1.key }) {
      guard schema.input(named: key) != nil else {
        collector.error("unknown_action_input", "Action '\(id)' has no input '\(key)'.", at: step.location)
        continue
      }
      guard case .string = value else {
        collector.error("action_input_type", "Action '\(id)' input '\(key)' must be a string.", at: step.location)
        continue
      }
    }
    for input in schema.inputs where input.required && inputs[input.name] == nil {
      collector.error("missing_action_input", "Action '\(id)' requires input '\(input.name)'.", at: step.location)
    }
    actionScopes[actionScopes.count - 1][step.id] = schema
  }

  private func checkJSONTemplates(_ value: WorkflowJSONValue, at location: WorkflowSourceLocation?) {
    switch value {
    case .string(let text): checkTemplate(text, at: location, consumer: .requiredActionInput)
    case .array(let values): for value in values { checkJSONTemplates(value, at: location) }
    case .object(let fields): for value in fields.values { checkJSONTemplates(value, at: location) }
    default: break
    }
  }

  private func checkControl(_ step: WorkflowStepDefinition, control: WorkflowControlStep) {
    let expressions: [String]
    switch control {
    case .set(let assignments):
      expressions = Array(assignments.values)
      for name in assignments.keys where definition.state[name] == nil {
        collector.error("unknown_state", "Unknown state field '\(name)'.", at: step.location)
      }
    case .conditional(let condition, _, _), .loop(let condition, _, _): expressions = [condition]
    case .breakLoop, .continueLoop: expressions = []
    }
    for expression in expressions {
      do {
        var parser = try WorkflowExpressionParser(expression)
        let node = try parser.parse()
        checkReferenceSpelling(node, at: step.location)
        for parts in node.requiredReferences {
          checkReference(
            WorkflowTemplate.Reference(path: parts.joined(separator: ".")), at: step.location, consumer: .template)
        }
      } catch { collector.error("expression_syntax", "\(error)", at: step.location) }
    }
    let previousOutputs = deliveries
    let previousOuterNames = outerOutputNames
    outerOutputNames.formUnion(deliveries.keys)
    defer { outerOutputNames = previousOuterNames }
    let previousRoles = launchedRoles
    let previousPossibleRoles = possiblyLaunchedRoles
    var branchRoles: [Set<String>] = []
    var possibleRoles = previousPossibleRoles
    let branches: [[WorkflowStepDefinition]]
    if case .conditional(_, let yes, let otherwise) = control {
      branches = [yes, otherwise]
    } else {
      branches = [step.action.children]
    }
    for branch in branches {
      actionScopes.append([:])
      branch.forEach(checkStep)
      branchRoles.append(launchedRoles)
      possibleRoles.formUnion(possiblyLaunchedRoles)
      actionScopes.removeLast()
      deliveries = previousOutputs
      launchedRoles = previousRoles
      possiblyLaunchedRoles = previousPossibleRoles
    }
    if case .conditional = control, let first = branchRoles.first {
      launchedRoles = branchRoles.dropFirst().reduce(first) { $0.intersection($1) }
      possiblyLaunchedRoles = possibleRoles
    }
  }

  // MARK: Expect

  private func checkExpect(_ expect: WorkflowExpectation?, step: WorkflowStepDefinition) {
    guard let expect, let name = step.deliveryName else { return }
    if outerOutputNames.contains(name) {
      collector.error(
        "output_shadowing",
        "Output '\(name)' would overwrite an outer scope. Use a distinct output name and retain values in state.",
        at: step.location)
    }
    let location = expect.location ?? step.location
    if !WorkflowSchema.isSlug(name) {
      collector.error("output_name_slug", "Output name '\(name)' is not a valid slug.", at: location)
    }
    if expect.sections.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
      collector.error("section_empty", "'sections' entries must not be empty.", at: location)
    }
    if let verdict = expect.verdicts {
      checkVerdict(verdict, at: location)
    }
    if let timeout = expect.timeoutSeconds, timeout > WorkflowValidator.longTimeoutSeconds {
      collector.warning("timeout_long", "'timeout' above 2h; the watchdog already supervises waiting.", at: location)
    }
    var info = deliveries[name] ?? OutputInfo()
    let verdicts = expect.verdicts.map(Set.init)
    info.producers.append(OutputProducer(verdicts: verdicts, loopID: currentLoopID))
    info.latestVerdicts = verdicts
    if expect.onTimeout == .skip {
      skipOutputs.append(
        SkipRecord(
          name: name, use: OutputUse(consumer: .template, ordinal: ordinal, loopID: currentLoopID), location: location))
    }
    deliveries[name] = info
  }

  private func checkVerdict(_ verdict: [String], at location: WorkflowSourceLocation?) {
    if !WorkflowSchema.verdictRange.contains(verdict.count) {
      collector.error("verdict_count", "'verdicts' declares 2–4 values.", at: location)
    }
    if Set(verdict).count != verdict.count {
      collector.error("verdict_duplicate", "'verdicts' repeats a value.", at: location)
    }
    for value in verdict where !WorkflowSchema.isSlug(value) {
      collector.error("verdict_slug", "Verdict '\(value)' is not a valid slug.", at: location)
    }
  }

  /// A skipped delivery ends the run only when a non-optional reader comes after it — later in
  /// document order, or anywhere in the same loop body, which the next iteration reads again.
  private func reportSkipConsumers() {
    for record in skipOutputs {
      let (name, skip, location) = (record.name, record.use, record.location)
      let blocking = (consumers[name] ?? []).contains { use in
        use.consumer != .optionalActionInput
          && (use.ordinal > skip.ordinal || (use.loopID != nil && use.loopID == skip.loopID))
      }
      guard blocking else { continue }
      collector.warning(
        "skip_ends_run",
        "'on_timeout: skip' on output '\(name)' would end the run: a later step depends on it.",
        at: location)
    }
  }

  // MARK: Templates

  private func checkTemplate(_ text: String, at location: WorkflowSourceLocation?, consumer: OutputConsumer) {
    var remaining = text[...]
    while let start = remaining.range(of: "{{") {
      remaining = remaining[start.upperBound...]
      guard let end = remaining.range(of: "}}") else {
        collector.error("template_syntax", "Unclosed expression.", at: location)
        return
      }
      checkExpression(String(remaining[..<end.lowerBound]), at: location, consumer: consumer)
      remaining = remaining[end.upperBound...]
    }
    if remaining.contains("}}") { collector.error("template_syntax", "Unexpected expression delimiter.", at: location) }
  }

  private func checkExpression(_ expression: String, at location: WorkflowSourceLocation?, consumer: OutputConsumer) {
    do {
      var parser = try WorkflowExpressionParser(expression)
      let node = try parser.parse()
      checkReferenceSpelling(node, at: location)
      for parts in node.requiredReferences {
        checkReference(WorkflowTemplate.Reference(path: parts.joined(separator: ".")), at: location, consumer: consumer)
      }
    } catch { collector.error("expression_syntax", "\(error)", at: location) }
  }

  /// Optional access permits absent values, not unknown namespace or metadata names.
  private func checkReferenceSpelling(_ node: WorkflowExpressionNode, at location: WorkflowSourceLocation?) {
    let required = Set(node.requiredReferences)
    for parts in node.references where !required.contains(parts) {
      let valid: Bool
      switch parts.first {
      case "context": valid = checkContextReference(parts)
      case "inputs", "state": valid = true
      case "deliveries": valid = parts.count < 3 || (parts.count == 3 && ["path", "verdict"].contains(parts[2]))
      case "actions": valid = parts.count < 3 || ["output", "output_path"].contains(parts[2])
      default: valid = false
      }
      if !valid {
        collector.error("unknown_variable", "Unknown variable '{{ \(parts.joined(separator: ".")) }}'.", at: location)
      }
    }
  }

  private func checkReference(
    _ reference: WorkflowTemplate.Reference, at location: WorkflowSourceLocation?, consumer: OutputConsumer
  ) {
    let parts = reference.components
    let valid: Bool
    switch parts.first {
    case "context":
      valid = checkContextReference(parts)
    case "inputs": valid = parts.count >= 2 && definition.input(named: parts[1]) != nil
    case "state": valid = parts.count >= 2 && definition.state[parts[1]] != nil
    case "deliveries": valid = parts.count == 3 && checkOutputReference(parts, at: location, consumer: consumer)
    case "actions": valid = parts.count >= 3 && checkActionReference(parts)
    default: valid = false
    }
    if !valid {
      collector.error("unknown_variable", "Unknown or unavailable variable '{{ \(reference.path) }}'.", at: location)
    }
  }

  private func checkContextReference(_ parts: [String]) -> Bool {
    guard parts.count >= 2 else { return true }
    let fields: [String: Set<String>] = [
      "workflow": ["id", "name"],
      "run": ["id", "path"],
      "worktree": ["id", "path", "name", "branch", "captured_at"],
      "initiator": ["pane_id", "tab_id"], "step": ["id", "iteration", "captured_at"],
      "action": ["execution_id", "step_id", "attempt", "working_directory", "artifacts_directory"],
    ]
    if parts[1] == "action", !checkingActionInputs { return false }
    if parts[1] == "roles" {
      guard parts.count > 2 else { return true }
      guard definition.role(named: parts[2]) != nil else { return false }
      return parts.count == 3
        || (parts.count == 4 && ["source", "display_name", "agent", "pane_id", "observed"].contains(parts[3]))
        || (parts.count == 5 && parts[3] == "observed" && ["exists", "state"].contains(parts[4]))
    }
    guard let allowed = fields[parts[1]] else { return false }
    return parts.count == 2 || (parts.count == 3 && allowed.contains(parts[2]))
  }

  private func checkOutputReference(
    _ parts: [String], at location: WorkflowSourceLocation?, consumer: OutputConsumer
  ) -> Bool {
    guard let info = deliveries[parts[1]], ["path", "verdict"].contains(parts[2]) else { return false }
    if parts[2] == "verdict", info.latestVerdicts == nil {
      return false
    }
    consumers[parts[1], default: []].append(OutputUse(consumer: consumer, ordinal: ordinal, loopID: currentLoopID))
    return true
  }

  private func checkActionReference(_ parts: [String]) -> Bool {
    for scope in actionScopes.reversed() {
      if let schema = scope[parts[1]] {
        return schema.hasOutput(named: parts[2])
      }
    }
    return false
  }

  // MARK: Helpers

  private func requireRole(_ name: String, at location: WorkflowSourceLocation?) -> WorkflowRoleDefinition? {
    guard let role = definition.role(named: name) else {
      collector.error("undefined_role", "Role '\(name)' is not defined.", at: location)
      return nil
    }
    return role
  }

  private func warnIfSpellingCompletion(_ text: String, at location: WorkflowSourceLocation?) {
    if text.contains(WorkflowValidator.completionCommand) {
      collector.warning(
        "spells_completion_command",
        "Do not spell '\(WorkflowValidator.completionCommand)'; the runner appends the generated completion command.",
        at: location)
    }
  }
}
