import Foundation
import ProwlCLIShared

@MainActor
struct WorkflowStatusCenterPresentation: Equatable {
  let runs: [WorkflowRunPresentation]

  init(
    state: WorkflowRunsFeature.State,
    selectedWorktreeID: Worktree.ID?,
    now: Date
  ) {
    guard let selectedWorktreeID else {
      runs = []
      return
    }
    runs = state.activeSessions
      .map(\.run)
      .filter { $0.context.worktree.id == selectedWorktreeID }
      .sorted {
        if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
        if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
        return $0.id.uuidString > $1.id.uuidString
      }
      .map { WorkflowRunPresentation(run: $0, now: now) }
  }

  var primary: WorkflowRunPresentation? { runs.first }
  var attentionRun: WorkflowRunPresentation? { runs.first { $0.status.isAttention } }
  var activeRunCount: Int { runs.count }
  var hasAttention: Bool { attentionRun != nil }
}

nonisolated struct WorkflowRunPresentation: Equatable, Sendable, Identifiable {
  enum Status: Equatable, Sendable {
    case running
    case needsAttention(String)
  }

  let id: UUID
  let workflowName: String
  let workflowIcon: String
  let worktreeID: Worktree.ID
  let worktreeName: String
  let startedAt: Date
  let elapsedText: String
  let status: Status
  let currentStepTitle: String
  let currentPrompt: String?
  let roles: [WorkflowRolePresentation]
  let stepItems: [WorkflowStepListItem]
  let attentionControls: [WorkflowAttentionControl]
  let runDirectory: URL
  let logURL: URL

  init(run: WorkflowRun, now: Date) {
    id = run.id
    workflowName = run.definition.name
    workflowIcon = run.definition.icon ?? "point.3.connected.trianglepath.dotted"
    worktreeID = run.context.worktree.id
    worktreeName = run.context.worktree.name
    startedAt = run.startedAt
    elapsedText = Self.elapsedText(from: run.startedAt, to: now)
    status = run.status.attention.map { .needsAttention($0.message) } ?? .running
    let context = Self.templateContext(for: run, iteration: run.currentIteration)
    currentStepTitle = Self.title(for: run.currentStep, context: context) ?? "Finishing workflow"
    currentPrompt = Self.prompt(for: run.currentStep, context: context)
    roles = run.definition.roles.map { role in
      WorkflowRolePresentation(role: role, binding: run.bindings[role.name])
    }
    stepItems = Self.stepItems(for: run)
    if let attention = run.status.attention {
      let machine = WorkflowRunMachine(
        run: run,
        limits: WorkflowDeliveryLimits(),
        now: { now },
        makeToken: { "presentation-does-not-mint-tokens" }
      )
      let skipConsequence = machine.skipConsequence(forStep: attention.stepID)
      attentionControls = attention.actions.map {
        WorkflowAttentionControl(
          action: $0,
          run: run,
          attention: attention,
          skipConsequence: skipConsequence
        )
      }
    } else {
      attentionControls = []
    }
    runDirectory = run.runDirectory
    logURL = run.runDirectory.appending(path: "log.md", directoryHint: .notDirectory)
  }

  func elapsedText(at now: Date) -> String {
    Self.elapsedText(from: startedAt, to: now)
  }

  private static func elapsedText(from start: Date, to end: Date) -> String {
    let seconds = max(0, Int(end.timeIntervalSince(start)))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    if hours < 24 {
      return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }
    let days = hours / 24
    let remainingHours = hours % 24
    return remainingHours == 0 ? "\(days)d" : "\(days)d \(remainingHours)h"
  }

  private static func templateContext(for run: WorkflowRun, iteration: Int?) -> [String: WorkflowJSONValue] {
    var values = run.stepValues.isEmpty ? run.expressionValues(capturedAt: run.updatedAt) : run.stepValues
    if case .object(var context) = values["context"], case .object(var step) = context["step"] {
      step["iteration"] = iteration.map(WorkflowJSONValue.integer) ?? .null
      context["step"] = .object(step)
      values["context"] = .object(context)
    }
    return values
  }

  private static func title(
    for step: WorkflowStepDefinition?,
    context: [String: WorkflowJSONValue]
  ) -> String? {
    guard let step else { return nil }
    guard let title = step.title else { return Self.fallbackTitle(for: step) }
    return (try? WorkflowExpression.renderText(title, values: context)) ?? title
  }

  private static func fallbackTitle(for step: WorkflowStepDefinition) -> String {
    step.historyTitle
  }

  private static func prompt(
    for step: WorkflowStepDefinition?,
    context: [String: WorkflowJSONValue]
  ) -> String? {
    guard let step else { return nil }
    let source: String?
    switch step.action {
    case .message(_, let prompt, _):
      source = prompt
    case .launch(_, let prompt, _, _):
      source = prompt
    case .action(let id, _):
      source = "Run action \(id)."
    case .notify(let text):
      source = text
    case .close(let role):
      source = "Close the pane bound to \(role)."
    case .control:
      source = nil
    }
    guard let source else { return nil }
    return (try? WorkflowExpression.renderText(source, values: context)) ?? source
  }

  private static func stepItems(for run: WorkflowRun) -> [WorkflowStepListItem] {
    var items: [WorkflowStepListItem] = []
    for step in run.definition.steps {
      switch step.action {
      case .control(.loop(_, let maximum, let children)):
        let body = children.flatMap { [$0] + $0.action.descendants }
        let recordedIterations = run.stepRecords.compactMap { record in
          body.contains { $0.id == record.stepID } ? record.iteration : nil
        }
        var iterations = Set(recordedIterations)
        if body.contains(where: { $0.id == run.currentStep?.id }),
          let current = run.currentIteration
        {
          iterations.insert(current)
        }
        if iterations.isEmpty {
          items.append(
            .step(
              WorkflowStepPresentation(
                id: "\(step.id)-pending",
                stepID: step.id,
                title: title(for: step, context: templateContext(for: run, iteration: nil)) ?? step.id,
                state: .pending
              )))
        } else {
          for iteration in iterations.sorted() {
            let steps = body.map { inner in
              let record = run.stepRecords.last {
                $0.stepID == inner.id && $0.iteration == iteration
              }
              let context = templateContext(for: run, iteration: iteration)
              return WorkflowStepPresentation(
                id: "\(step.id)-\(iteration)-\(inner.id)",
                stepID: inner.id,
                title: title(for: inner, context: context) ?? inner.id,
                state: record.map { WorkflowStepPresentation.State($0.state) } ?? .pending
              )
            }
            items.append(
              .round(
                WorkflowRoundPresentation(
                  id: "\(step.id)-\(iteration)",
                  index: iteration,
                  maximum: maximum,
                  steps: steps
                )))
          }
        }
      case .control(.conditional(_, let yes, let otherwise)):
        for child in [step] + (yes + otherwise).flatMap({ [$0] + $0.action.descendants }) {
          let record = run.stepRecords.last { $0.stepID == child.id }
          let context = templateContext(for: run, iteration: record?.iteration)
          items.append(
            .step(
              .init(
                id: child.id, stepID: child.id,
                title: title(for: child, context: context) ?? child.id,
                state: record.map { .init($0.state) } ?? .pending)))
        }
      default:
        let record = run.stepRecords.last { $0.stepID == step.id && $0.iteration == nil }
        let context = templateContext(for: run, iteration: nil)
        items.append(
          .step(
            WorkflowStepPresentation(
              id: "\(step.id)-top",
              stepID: step.id,
              title: title(for: step, context: context) ?? step.id,
              state: record.map { WorkflowStepPresentation.State($0.state) } ?? .pending
            )))
      }
    }
    return items
  }
}

nonisolated extension WorkflowRunPresentation.Status {
  var isAttention: Bool {
    if case .needsAttention = self { return true }
    return false
  }
}

nonisolated struct WorkflowRolePresentation: Equatable, Sendable, Identifiable {
  let id: String
  let displayName: String
  let agent: String?
  let paneHandle: String?
  let surfaceID: UUID?

  init(role: WorkflowRoleDefinition, binding: WorkflowRoleBinding?) {
    id = role.name
    displayName = binding?.displayName ?? role.name
    agent = binding?.agent.nilIfEmpty
    paneHandle = binding?.pane?.handle
    surfaceID = binding?.pane?.surfaceID
  }
}

nonisolated enum WorkflowStepListItem: Equatable, Sendable, Identifiable {
  case step(WorkflowStepPresentation)
  case round(WorkflowRoundPresentation)

  var id: String {
    switch self {
    case .step(let step): step.id
    case .round(let round): round.id
    }
  }
}

nonisolated struct WorkflowRoundPresentation: Equatable, Sendable, Identifiable {
  let id: String
  let index: Int
  let maximum: Int?
  let steps: [WorkflowStepPresentation]
}

nonisolated struct WorkflowStepPresentation: Equatable, Sendable, Identifiable {
  enum State: Equatable, Sendable {
    case pending
    case active
    case completed
    case skipped
    case failed

    init(_ state: WorkflowStepState) {
      switch state {
      case .active: self = .active
      case .completed: self = .completed
      case .skipped: self = .skipped
      case .failed: self = .failed
      }
    }
  }

  let id: String
  let stepID: String
  let title: String
  let state: State
}

nonisolated enum WorkflowRunPanelIntent: Equatable, Sendable {
  case focusPane(worktreeID: Worktree.ID, surfaceID: UUID)
  case userAction(runID: UUID, action: WorkflowUserAction)
  case revealRunFolder(URL)
  case openLog(URL)
}

nonisolated struct WorkflowAttentionControl: Equatable, Sendable, Identifiable {
  var id: WorkflowAttentionAction { action }
  let action: WorkflowAttentionAction
  let label: String
  let systemImage: String
  let isDestructive: Bool
  let focusSurfaceID: UUID?
  let verdicts: [String]
  let confirmationMessage: String?

  init(
    action: WorkflowAttentionAction,
    run: WorkflowRun,
    attention: WorkflowAttention,
    skipConsequence: WorkflowSkipConsequence
  ) {
    self.action = action
    let rolePane = attention.role.flatMap { run.bindings[$0]?.pane }
    focusSurfaceID = action == .focusPane ? rolePane?.surfaceID : nil
    verdicts = action == .acceptWithVerdict ? (run.activeActivation?.expect.verdicts ?? []) : []
    isDestructive = action == .cancel
    switch action {
    case .focusPane:
      label = "Focus Pane"
      systemImage = "scope"
      confirmationMessage = nil
    case .nudge:
      label = "Nudge Again"
      systemImage = "bell.badge"
      confirmationMessage = nil
    case .keepWaiting:
      label = "Keep Waiting"
      systemImage = "clock"
      confirmationMessage = nil
    case .retry:
      label = "Retry"
      systemImage = "arrow.clockwise"
      confirmationMessage = nil
    case .relaunch:
      label = "Relaunch Role"
      systemImage = "arrow.trianglehead.2.clockwise.rotate.90"
      confirmationMessage = nil
    case .acceptDelivery:
      label = "Accept as Delivered"
      systemImage = "checkmark"
      confirmationMessage = nil
    case .acceptWithVerdict:
      label = "Accept with Verdict"
      systemImage = "checkmark.circle"
      confirmationMessage = nil
    case .askAgain:
      label = "Ask Again"
      systemImage = "arrowshape.turn.up.left"
      confirmationMessage = nil
    case .skip:
      label = "Skip Step"
      systemImage = "forward.end"
      confirmationMessage = Self.skipConfirmation(
        stepID: attention.stepID,
        consequence: skipConsequence
      )
    case .cancel:
      label = "Cancel Run"
      systemImage = "xmark"
      confirmationMessage = "Cancel this workflow run? Its panes and deliveries will be kept."
    }
  }

  func intent(
    runID: UUID,
    worktreeID: Worktree.ID,
    verdict: String? = nil
  ) -> WorkflowRunPanelIntent? {
    switch action {
    case .focusPane:
      guard let focusSurfaceID else { return nil }
      return .focusPane(worktreeID: worktreeID, surfaceID: focusSurfaceID)
    case .nudge:
      return .userAction(runID: runID, action: .nudge)
    case .keepWaiting:
      return .userAction(runID: runID, action: .keepWaiting)
    case .retry:
      return .userAction(runID: runID, action: .retry)
    case .relaunch:
      return .userAction(runID: runID, action: .relaunch)
    case .acceptDelivery:
      return .userAction(runID: runID, action: .acceptDelivery(verdict: nil))
    case .acceptWithVerdict:
      guard let verdict, verdicts.contains(verdict) else { return nil }
      return .userAction(runID: runID, action: .acceptDelivery(verdict: verdict))
    case .askAgain:
      return .userAction(runID: runID, action: .askAgain)
    case .skip:
      return .userAction(runID: runID, action: .skip)
    case .cancel:
      return .userAction(runID: runID, action: .cancel)
    }
  }

  private static func skipConfirmation(
    stepID: String,
    consequence: WorkflowSkipConsequence
  ) -> String {
    switch consequence {
    case .noDelivery:
      "Skip step '\(stepID)'? The workflow continues without an output from this step."
    case .continues(let optionalInputs):
      if optionalInputs.isEmpty {
        "Skip step '\(stepID)'? The workflow continues without this delivery."
      } else {
        "Skip step '\(stepID)'? The workflow continues without the optional input used by "
          + optionalInputs.joined(separator: ", ") + "."
      }
    case .endsRun(let dependent):
      "Skip step '\(stepID)'? This ends the run because step '\(dependent)' depends on its output."
    }
  }
}
nonisolated extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
nonisolated extension Collection {
  fileprivate subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
