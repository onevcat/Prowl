// supacode/CLIService/FocusCommandHandler.swift
// Handles `prowl focus` by resolving, focusing, and returning final pane context.

import Foundation
import ProwlCLIShared

/// Resolved target metadata for focus payload construction.
struct FocusResolvedTarget: Sendable {
  let worktreeID: String
  let worktreeName: String
  let worktreePath: String
  let worktreeRootPath: String
  let worktreeKind: ListCommandWorktree.Kind
  let tabID: UUID
  let tabTitle: String
  let tabSelected: Bool
  let paneID: UUID
  let paneTitle: String
  let paneCWD: String?
  let paneFocused: Bool
}

extension FocusResolvedTarget {
  init(from resolved: ResolvedTarget) {
    self.worktreeID = resolved.worktreeID
    self.worktreeName = resolved.worktreeName
    self.worktreePath = resolved.worktreePath
    self.worktreeRootPath = resolved.worktreeRootPath
    self.worktreeKind = resolved.worktreeKind
    self.tabID = resolved.tabID
    self.tabTitle = resolved.tabTitle
    self.tabSelected = resolved.tabSelected
    self.paneID = resolved.paneID
    self.paneTitle = resolved.paneTitle
    self.paneCWD = resolved.paneCWD
    self.paneFocused = resolved.paneFocused
  }
}

@MainActor
final class FocusCommandHandler: CommandHandler {
  typealias ResolveProvider = @MainActor (TargetSelector) -> Result<FocusResolvedTarget, TargetResolverError>
  typealias FocusPerformer = @MainActor (FocusResolvedTarget) -> Bool
  typealias BringToFront = @MainActor () -> Bool

  private let resolveProvider: ResolveProvider
  private let focusPerformer: FocusPerformer
  private let bringToFront: BringToFront

  init(
    resolveProvider: @escaping ResolveProvider,
    focusPerformer: @escaping FocusPerformer,
    bringToFront: @escaping BringToFront
  ) {
    self.resolveProvider = resolveProvider
    self.focusPerformer = focusPerformer
    self.bringToFront = bringToFront
  }

  func handle(envelope: CommandEnvelope) -> CommandResponse {
    guard case .focus(let input) = envelope.command else {
      return errorResponse(code: CLIErrorCode.focusFailed, message: "Invalid command.")
    }

    let requested = makeRequestedTarget(from: input.selector)

    // Resolve requested selector.
    let requestedTarget: FocusResolvedTarget
    switch resolveProvider(input.selector) {
    case .success(let target):
      requestedTarget = target
    case .failure(let error):
      return mapResolverError(error)
    }

    // Apply focus operation.
    guard focusPerformer(requestedTarget) else {
      return errorResponse(code: CLIErrorCode.focusFailed, message: "Failed to focus requested target.")
    }

    // Bring app window to front.
    guard bringToFront() else {
      return errorResponse(code: CLIErrorCode.focusFailed, message: "Failed to bring Prowl to front.")
    }

    // Always return the final active pane context for command chaining.
    let finalTarget: FocusResolvedTarget
    switch resolveProvider(.none) {
    case .success(let target):
      finalTarget = target
    case .failure:
      return errorResponse(code: CLIErrorCode.focusFailed, message: "Focused target could not be resolved.")
    }

    // Contract invariant: successful focus must end at selected tab + focused pane.
    guard finalTarget.tabSelected, finalTarget.paneFocused else {
      return errorResponse(code: CLIErrorCode.focusFailed, message: "Focused target was not activated.")
    }

    let payload = FocusCommandPayload(
      requested: requested,
      resolvedVia: makeResolvedVia(from: input.selector, requestedTarget: requestedTarget),
      broughtToFront: true,
      target: makePayloadTarget(from: finalTarget)
    )

    do {
      return try CommandResponse(
        ok: true,
        command: "focus",
        schemaVersion: "prowl.cli.focus.v1",
        data: RawJSON(encoding: payload)
      )
    } catch {
      return errorResponse(code: CLIErrorCode.focusFailed, message: "Failed to encode response.")
    }
  }

  private func makeRequestedTarget(from selector: TargetSelector) -> FocusRequestedTarget {
    switch selector {
    case .worktree(let value):
      return FocusRequestedTarget(selector: .worktree, value: value)
    case .tab(let value):
      return FocusRequestedTarget(selector: .tab, value: value)
    case .pane(let value):
      return FocusRequestedTarget(selector: .pane, value: value)
    case .auto(let value):
      return FocusRequestedTarget(selector: .auto, value: value)
    case .none:
      return FocusRequestedTarget(selector: .current, value: nil)
    }
  }

  private func makeResolvedVia(
    from selector: TargetSelector,
    requestedTarget: FocusResolvedTarget
  ) -> FocusResolvedVia {
    switch selector {
    case .worktree:
      return .worktree
    case .tab:
      return .tab
    case .pane, .none:
      return .pane
    case .auto(let value):
      if let uuid = UUID(uuidString: value) {
        if uuid == requestedTarget.paneID {
          return .pane
        }
        if uuid == requestedTarget.tabID {
          return .tab
        }
      }
      return .worktree
    }
  }

  private func makePayloadTarget(from target: FocusResolvedTarget) -> FocusTarget {
    FocusTarget(
      worktree: FocusTargetWorktree(
        id: target.worktreeID,
        name: target.worktreeName,
        path: target.worktreePath,
        rootPath: target.worktreeRootPath,
        kind: target.worktreeKind.rawValue
      ),
      tab: FocusTargetTab(
        id: target.tabID.uuidString,
        title: target.tabTitle,
        selected: target.tabSelected
      ),
      pane: FocusTargetPane(
        id: target.paneID.uuidString,
        title: target.paneTitle,
        cwd: target.paneCWD,
        focused: target.paneFocused
      )
    )
  }

  private func mapResolverError(_ error: TargetResolverError) -> CommandResponse {
    switch error {
    case .notFound(let message):
      return errorResponse(code: CLIErrorCode.targetNotFound, message: message)
    case .notUnique(let message):
      return errorResponse(code: CLIErrorCode.targetNotUnique, message: message)
    }
  }

  private func errorResponse(code: String, message: String) -> CommandResponse {
    CommandResponse(
      ok: false,
      command: "focus",
      schemaVersion: "prowl.cli.focus.v1",
      error: CommandError(code: code, message: message)
    )
  }
}
