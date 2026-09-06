// supacode/CLIService/PaneCommandHandler.swift

import Foundation
import ProwlCLIShared

@MainActor
final class PaneCommandHandler: CommandHandler {
  typealias ResolveProvider = @MainActor (TargetSelector) -> Result<TabResolvedTarget, TargetResolverError>
  typealias ClosePaneProvider = @MainActor (TabResolvedTarget, Bool) -> Bool

  private let resolveProvider: ResolveProvider
  private let closePane: ClosePaneProvider

  init(
    resolveProvider: @escaping ResolveProvider,
    closePane: @escaping ClosePaneProvider
  ) {
    self.resolveProvider = resolveProvider
    self.closePane = closePane
  }

  // swiftlint:disable:next async_without_await
  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    guard case .pane(let input) = envelope.command else {
      return errorResponse(code: CLIErrorCode.paneFailed, message: "Invalid command.")
    }

    if input.action == .close, input.selector.isNone {
      return errorResponse(
        code: CLIErrorCode.invalidArgument,
        message: "pane close requires an explicit target selector."
      )
    }

    let target: TabResolvedTarget
    switch resolveProvider(input.selector) {
    case .success(let resolved):
      target = resolved
    case .failure(let error):
      return mapResolverError(error)
    }

    switch input.action {
    case .close:
      guard closePane(target, input.force) else {
        return errorResponse(code: CLIErrorCode.paneFailed, message: "Failed to close pane.")
      }
      return success(action: .close, target: target)
    }
  }

  private func success(action: PaneAction, target: TabResolvedTarget) -> CommandResponse {
    do {
      return try CommandResponse(
        ok: true,
        command: "pane",
        schemaVersion: "prowl.cli.pane.v1",
        data: RawJSON(encoding: PaneCommandPayload(action: action, target: makePayloadTarget(from: target)))
      )
    } catch {
      return errorResponse(code: CLIErrorCode.paneFailed, message: "Failed to encode response.")
    }
  }

  private func makePayloadTarget(from target: TabResolvedTarget) -> TabTarget {
    TabTarget(
      worktree: TabTargetWorktree(
        id: target.worktreeID,
        name: target.worktreeName,
        path: target.worktreePath,
        rootPath: target.worktreeRootPath,
        kind: target.worktreeKind
      ),
      tab: TabTargetTab(
        id: target.tabID,
        title: target.tabTitle,
        selected: target.tabSelected
      ),
      pane: TabTargetPane(
        id: target.paneID,
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
      command: "pane",
      schemaVersion: "prowl.cli.pane.v1",
      error: CommandError(code: code, message: message)
    )
  }
}
