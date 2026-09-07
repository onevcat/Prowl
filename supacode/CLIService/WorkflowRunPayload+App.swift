// supacode/CLIService/WorkflowRunPayload+App.swift
// Maps a live `WorkflowRun` or a persisted `WorkflowRunRecord` to the `prowl workflow` wire
// payload (docs-ai 063 B3, decision W5). Delivery tokens never appear: the completion commands of
// the current activation are the only place a token is spelled, and only to the caller that
// already holds it (the `role` of the payload).

import Foundation
import ProwlCLIShared

extension WorkflowRunPayload {
  nonisolated static func makeDateFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }

  /// - Parameter callerRole: the role of the *verified* caller pane (socket peer ancestry) when it
  ///   is bound in the run; only then, and only for its own activation, does the payload spell the
  ///   completion commands (they carry the token). A manual or forced delivery passes nil.
  nonisolated init(run: WorkflowRun, callerRole: String?, includeSelfInitiated: Bool) {
    let formatter = Self.makeDateFormatter()
    let activation = run.activeActivation
    let spellsCompletion = callerRole != nil && activation?.role == callerRole
    let selfInitiated: WorkflowSelfInitiatedPayload? =
      if includeSelfInitiated, let line = run.selfInitiatedLine {
        WorkflowSelfInitiatedPayload(
          line: line,
          instructionPath: run.invocations.first?.instructionPath,
          completion: run.invocations.first?.activation?.completion.messageCommands ?? [])
      } else {
        nil
      }
    self.init(
      id: run.id.uuidString,
      workflow: WorkflowIdentity(id: run.definition.id, name: run.definition.name),
      scope: run.context.scope.workflowScope,
      definitionPath: run.context.definitionPath,
      source: .live,
      status: WorkflowRunStatusPayload(WorkflowRunRecord.Status(run.status)),
      step: run.status.isTerminal ? nil : run.currentStep?.id,
      role: callerRole,
      worktree: WorkflowRunWorktreePayload(
        id: run.context.worktree.id, name: run.context.worktree.name,
        branch: run.context.worktree.branch,
        path: run.context.worktree.path),
      runDirectory: WorkflowRunPaths.path(run.runDirectory),
      bindings: run.bindings.mapValues {
        WorkflowBindingPayload(source: $0.source, profile: $0.profile, pane: $0.pane)
      },
      // Only the pane that owns the activation (its role) is told the completion command; a
      // self-initiated line already carries the caller's own step and nothing else.
      activation: activation.map {
        WorkflowActivationPayload($0, spellCompletion: spellsCompletion, formatter: formatter)
      },
      deliveries: run.deliveries.mapValues { WorkflowDeliveryRecordPayload($0, formatter: formatter) },
      startedAt: formatter.string(from: run.startedAt),
      updatedAt: formatter.string(from: run.updatedAt),
      finishedAt: run.finishedAt.map(formatter.string(from:)),
      selfInitiated: selfInitiated
    )
  }

  /// A run read back from `run.json` after a restart: no tokens exist any more, so no completion
  /// commands, no activation, and no self-initiated line.
  nonisolated init(record: WorkflowRunRecord) {
    let formatter = Self.makeDateFormatter()
    self.init(
      id: record.run.id.uuidString,
      workflow: WorkflowIdentity(id: record.run.workflowID, name: record.run.workflowName),
      scope: record.run.scope.workflowScope,
      definitionPath: record.run.definitionPath,
      source: .record,
      status: WorkflowRunStatusPayload(record.run.status),
      step: record.run.status.isTerminal ? nil : record.steps.last { $0.state == .active }?.id,
      role: nil,
      worktree: WorkflowRunWorktreePayload(
        id: record.worktree.id, name: record.worktree.name, branch: record.worktree.branch,
        path: record.worktree.path),
      runDirectory: WorkflowRunPaths.path(
        (try? WorkflowHistoryStorage.configured.find(record.run.id))
          ?? WorkflowRunPaths.runDirectory(
            root: record.worktree.rootURL, runID: record.run.id, createdAt: record.run.startedAt)),
      bindings: record.bindings.mapValues {
        WorkflowBindingPayload(source: $0.source, profile: $0.profile, pane: $0.pane)
      },
      activation: nil,
      deliveries: record.deliveries.mapValues { WorkflowDeliveryRecordPayload($0, formatter: formatter) },
      startedAt: formatter.string(from: record.run.startedAt),
      updatedAt: formatter.string(from: record.run.updatedAt),
      finishedAt: record.run.finishedAt.map(formatter.string(from:)),
      selfInitiated: nil
    )
  }
}

extension WorkflowRunStatusPayload {
  nonisolated init(_ status: WorkflowRunRecord.Status) {
    self.init(
      state: status.state,
      step: status.step,
      dependent: status.dependent,
      attention: status.attention.map {
        WorkflowAttentionPayload(
          reason: $0.reason, message: $0.message, step: $0.step, role: $0.role, ordinal: $0.ordinal,
          actions: $0.actions.map(\.rawValue), issues: $0.issues)
      }
    )
  }
}

extension WorkflowBindingPayload {
  nonisolated init(
    source: WorkflowRoleSource, profile: WorkflowProfileBinding?, pane: WorkflowPaneIdentity?
  ) {
    self.init(
      source: source,
      profile: profile.map {
        WorkflowProfileBindingPayload(id: $0.id.uuidString, name: $0.name, agent: $0.agent)
      },
      pane: pane.map {
        WorkflowPaneBindingPayload(
          id: $0.surfaceID.uuidString, tabID: $0.tabID?.uuidString, handle: $0.handle,
          displayName: $0.displayName,
          agent: $0.agent)
      }
    )
  }
}

extension WorkflowActivationPayload {
  nonisolated init(
    _ activation: WorkflowActivation, spellCompletion: Bool, formatter: ISO8601DateFormatter
  ) {
    self.init(
      ordinal: activation.ordinal,
      step: activation.stepID,
      role: activation.role,
      state: activation.state.rawValue,
      dispatchID: activation.dispatchID,
      output: activation.deliveryName,
      expect: WorkflowExpectationPayload(
        format: activation.expect.format,
        sections: activation.expect.sections,
        verdicts: activation.expect.verdicts,
        strict: activation.expect.strict,
        completion: spellCompletion ? activation.completion.messageCommands : []),
      deadline: activation.deadline.map(formatter.string(from:))
    )
  }
}

extension WorkflowDeliveryRecordPayload {
  nonisolated init(_ output: WorkflowDeliveryRecord, formatter: ISO8601DateFormatter) {
    self.init(
      name: output.name,
      ordinal: output.ordinal,
      path: output.path,
      latestPath: output.latestPath,
      verdict: output.verdict,
      deliveredAt: formatter.string(from: output.deliveredAt)
    )
  }
}

extension WorkflowDeliveryPayload {
  nonisolated init(state: WorkflowDeliveryState, receipt: WorkflowDeliveryReceipt, role: String) {
    self.init(
      state: state,
      ordinal: receipt.ordinal,
      step: receipt.stepID,
      role: role,
      output: WorkflowDeliveryRecordPayload(receipt.output, formatter: WorkflowRunPayload.makeDateFormatter()),
      warnings: receipt.issues.map {
        WorkflowDeliveryWarningPayload(code: $0.code, message: $0.message)
      }
    )
  }
}
