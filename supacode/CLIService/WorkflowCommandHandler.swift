// supacode/CLIService/WorkflowCommandHandler.swift
// Handles `prowl workflow` over the socket (docs-ai 063 B1/B3): `list` resolves the worktree
// whose repo source is searched and runs three-source discovery; `run` resolves the source pane
// or worktree and hands admission to the runtime; `status`, `deliver`, and `cancel` are attributed by
// the caller pane and routed to the runtime coordinator.

import Foundation
import ProwlCLIShared

struct WorkflowRuntimeSnapshot {
  let resolution: TargetResolutionSnapshot
  let paneByShellPID: [pid_t: CallerPane]
  let bundleWorkflowsURL: URL?
  let userWorkflowsURL: URL
  /// `<scope>/<id>` keys of definitions the user switched off.
  let disabledWorkflowIDs: Set<String>
  let bundledSkillIDs: Set<String>?
  let knownAgents: Set<String>
  let installedAgents: Set<String>?
  /// Preset fields of the enabled Agent Profiles, for the `suggest` match warning.
  let enabledProfiles: [WorkflowProfileSuggestion]
}

@MainActor
final class WorkflowCommandHandler: CommandHandler {
  typealias SnapshotProvider = @MainActor () -> WorkflowRuntimeSnapshot

  private let snapshotProvider: SnapshotProvider
  private let runtime: WorkflowRuntimeCoordinator?

  init(snapshotProvider: @escaping SnapshotProvider, runtime: WorkflowRuntimeCoordinator? = nil) {
    self.snapshotProvider = snapshotProvider
    self.runtime = runtime
  }

  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    await handle(envelope: envelope, context: CLICommandContext())
  }

  func handle(envelope: CommandEnvelope, context: CLICommandContext) async -> CommandResponse {
    guard case .workflow(let input) = envelope.command else {
      return failure(code: CLIErrorCode.invalidArgument, message: "Expected a workflow command.")
    }
    let snapshot = snapshotProvider()
    let callerPane = callerPane(context: context, paneByShellPID: snapshot.paneByShellPID)
    switch input.action {
    case .list:
      switch resolveWorktree(input.target, snapshot: snapshot, callerPane: callerPane) {
      case .failure(.notFound(let message)):
        return failure(code: CLIErrorCode.targetNotFound, message: message)
      case .failure(.notUnique(let message)):
        return failure(code: CLIErrorCode.targetNotUnique, message: message)
      case .success(let worktree):
        do {
          let payload = try listPayload(worktree: worktree, snapshot: snapshot)
          return try CommandResponse(
            ok: true,
            command: WorkflowCommandPayload.commandName,
            schemaVersion: WorkflowCommandPayload.schemaVersion,
            data: RawJSON(encoding: WorkflowCommandPayload.list(payload))
          )
        } catch {
          return failure(
            code: CLIErrorCode.workflowFailed, message: "Failed to list workflows: \(error)")
        }
      }
    case .run, .status, .deliver, .cancel, .read:
      guard let runtime else { return notConfigured() }
      return await handleRuntime(
        input, runtime: runtime, snapshot: snapshot, callerPane: callerPane)
    }
  }

  private func handleRuntime(
    _ input: WorkflowInput,
    runtime: WorkflowRuntimeCoordinator,
    snapshot: WorkflowRuntimeSnapshot,
    callerPane: CallerPane?
  ) async -> CommandResponse {
    switch input.action {
    case .list:
      return failure(
        code: CLIErrorCode.invalidArgument, message: "Expected a runtime workflow action.")
    case .run:
      switch resolveSource(input.target, snapshot: snapshot, callerPane: callerPane) {
      case .failure(let refusal):
        return refusal.response
      case .success(let source):
        return await runtime.run(input, source: source, snapshot: snapshot)
      }
    case .read:
      return await runtime.read(input, callerPane: callerPane)
    case .status:
      return runtime.status(input, callerPane: callerPane)
    case .deliver:
      return await runtime.deliver(input, callerPane: callerPane)
    case .cancel:
      return runtime.cancel(input, callerPane: callerPane)
    }
  }

  // MARK: - Source resolution

  /// `run`: the caller's own pane, or an explicit target. A pane or tab target names the pane the
  /// `current` role binds to; a worktree target names no pane (decision W2).
  func resolveSource(
    _ selector: TargetSelector, snapshot: WorkflowRuntimeSnapshot, callerPane: CallerPane?
  ) -> Result<WorkflowRunSource, WorkflowCommandRefusal> {
    let resolver = TargetResolver { snapshot.resolution }
    if case .none = selector {
      if let callerPane,
        let worktree = snapshot.resolution.worktrees.first(where: { $0.id == callerPane.worktreeID }
        )
      {
        return .success(
          WorkflowRunSource(worktree: worktree, paneID: callerPane.surfaceID, paneIsCaller: true))
      }
      guard case .success(let focused) = resolver.resolve(.none),
        let worktree = snapshot.resolution.worktrees.first(where: { $0.id == focused.worktreeID })
      else {
        return .failure(
          refusal(
            code: CLIErrorCode.sourceRequired,
            message:
              "Run `prowl workflow run` inside a Prowl pane, or pass a pane or worktree target."))
      }
      return .success(WorkflowRunSource(worktree: worktree, paneID: nil, paneIsCaller: false))
    }
    switch resolver.resolve(selector) {
    case .failure(.notFound(let message)):
      return .failure(refusal(code: CLIErrorCode.targetNotFound, message: message))
    case .failure(.notUnique(let message)):
      return .failure(refusal(code: CLIErrorCode.targetNotUnique, message: message))
    case .success(let resolved):
      guard
        let worktree = snapshot.resolution.worktrees.first(where: { $0.id == resolved.worktreeID })
      else {
        return .failure(
          refusal(
            code: CLIErrorCode.targetNotFound, message: "The target's worktree was not found."))
      }
      let paneID = Self.addressesPane(selector, snapshot: snapshot) ? resolved.paneID : nil
      return .success(
        WorkflowRunSource(
          worktree: worktree, paneID: paneID,
          paneIsCaller: paneID != nil && paneID == callerPane?.surfaceID))
    }
  }

  /// Whether a selector named a pane or a tab (whose focused pane stands in), not a worktree.
  static func addressesPane(_ selector: TargetSelector, snapshot: WorkflowRuntimeSnapshot) -> Bool {
    switch selector {
    case .pane, .tab:
      return true
    case .none, .worktree:
      return false
    case .auto(let value):
      if value.hasPrefix("p") || value.hasPrefix("t"), Int(value.dropFirst()) != nil { return true }
      guard let id = UUID(uuidString: value) else { return false }
      return snapshot.resolution.worktrees.contains { worktree in
        worktree.tabs.contains { $0.id == id || $0.panes.contains { $0.id == id } }
      }
    }
  }

  // MARK: - Worktree resolution

  /// `.none` prefers the caller's own pane, then the focused worktree; nil means no worktree
  /// could be resolved and only the bundle and user sources are searched.
  private func resolveWorktree(
    _ selector: TargetSelector,
    snapshot: WorkflowRuntimeSnapshot,
    callerPane: CallerPane?
  ) -> Result<TargetResolutionSnapshot.Worktree?, TargetResolverError> {
    let resolver = TargetResolver { snapshot.resolution }
    if case .none = selector {
      if let callerPane,
        let worktree = snapshot.resolution.worktrees.first(where: { $0.id == callerPane.worktreeID }
        )
      {
        return .success(worktree)
      }
      guard case .success(let focused) = resolver.resolve(.none) else {
        return .success(nil)
      }
      return .success(snapshot.resolution.worktrees.first { $0.id == focused.worktreeID })
    }
    return resolver.resolve(selector).map { resolved in
      snapshot.resolution.worktrees.first { $0.id == resolved.worktreeID }
    }
  }

  private func callerPane(context: CLICommandContext, paneByShellPID: [pid_t: CallerPane])
    -> CallerPane?
  {
    if !context.callerProcessAncestry.isEmpty {
      return CallerPaneResolver.pane(
        forCallerProcessAncestry: context.callerProcessAncestry, paneByShellPID: paneByShellPID)
    }
    guard let callerProcessID = context.callerProcessID else { return nil }
    return CallerPaneResolver.pane(
      forCallerProcess: callerProcessID, paneByShellPID: paneByShellPID)
  }

  // MARK: - Listing

  private func listPayload(
    worktree: TargetResolutionSnapshot.Worktree?, snapshot: WorkflowRuntimeSnapshot
  ) throws -> WorkflowListPayload {
    let repoURL = worktree.map {
      WorkflowSources.repoDirectory(root: URL(filePath: $0.rootPath, directoryHint: .isDirectory))
    }
    let sources = WorkflowSources(
      bundle: snapshot.bundleWorkflowsURL, user: snapshot.userWorkflowsURL, repo: repoURL)
    let catalog = try WorkflowDiscovery.catalog(sources: sources) { scope in
      WorkflowValidationContext(
        scope: scope,
        bundledSkillIDs: snapshot.bundledSkillIDs,
        knownAgents: snapshot.knownAgents,
        installedAgents: snapshot.installedAgents,
        enabledProfiles: snapshot.enabledProfiles
      )
    }
    let workflows = catalog.map { entry in
      let enabled =
        entry.file.id.flatMap {
          WorkflowPreferenceKey.make(
            scope: entry.file.scope,
            workflowID: $0,
            repositoryRootPath: worktree?.rootPath)
        }.map { !snapshot.disabledWorkflowIDs.contains($0) } ?? false
      return WorkflowListEntry(entry: entry, enabled: enabled)
    }
    return WorkflowListPayload(
      worktree: worktree.map {
        WorkflowListWorktree(id: $0.id, name: $0.name, path: $0.path, rootPath: $0.rootPath)
      },
      sources: WorkflowListSources(
        bundle: sources.bundle?.path(percentEncoded: false),
        user: sources.user.path(percentEncoded: false),
        repo: sources.repo?.path(percentEncoded: false)
      ),
      workflows: workflows
    )
  }

  private func notConfigured() -> CommandResponse {
    failure(code: "NOT_IMPLEMENTED", message: "Workflow runtime is not configured.")
  }

  private func failure(code: String, message: String) -> CommandResponse {
    WorkflowCLIRendezvous.failure(code: code, message: message)
  }

  private func refusal(code: String, message: String) -> WorkflowCommandRefusal {
    WorkflowCommandRefusal(response: failure(code: code, message: message))
  }
}
