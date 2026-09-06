// supacode/CLIService/TabCommandHandler.swift

import Foundation
import ProwlCLIShared

struct TabResolvedTarget: Sendable, Equatable {
  let worktreeID: String
  let worktreeName: String
  let worktreePath: String
  let worktreeRootPath: String
  let worktreeKind: String
  let tabID: String
  let tabTitle: String
  let tabSelected: Bool
  let paneID: String
  let paneTitle: String
  let paneCWD: String?
  let paneFocused: Bool
}

extension TabResolvedTarget {
  init(from resolved: ResolvedTarget) {
    self.worktreeID = resolved.worktreeID
    self.worktreeName = resolved.worktreeName
    self.worktreePath = resolved.worktreePath
    self.worktreeRootPath = resolved.worktreeRootPath
    self.worktreeKind = resolved.worktreeKind.rawValue
    self.tabID = resolved.tabID.uuidString
    self.tabTitle = resolved.tabTitle
    self.tabSelected = resolved.tabSelected
    self.paneID = resolved.paneID.uuidString
    self.paneTitle = resolved.paneTitle
    self.paneCWD = resolved.paneCWD
    self.paneFocused = resolved.paneFocused
  }
}

extension TabTarget {
  init(from target: TabResolvedTarget) {
    self.init(
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
}

@MainActor
final class TabCommandHandler: CommandHandler {
  typealias ResolveProvider = @MainActor (TargetSelector) -> Result<TabResolvedTarget, TargetResolverError>
  typealias CreateTabProvider = @MainActor (TabResolvedTarget, String?) -> TabResolvedTarget?
  typealias CloseTabProvider = @MainActor (TabResolvedTarget, Bool) -> Bool

  private let resolveProvider: ResolveProvider
  private let createTab: CreateTabProvider
  private let closeTab: CloseTabProvider

  init(
    resolveProvider: @escaping ResolveProvider,
    createTab: @escaping CreateTabProvider,
    closeTab: @escaping CloseTabProvider
  ) {
    self.resolveProvider = resolveProvider
    self.createTab = createTab
    self.closeTab = closeTab
  }

  // swiftlint:disable:next async_without_await
  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    guard case .tab(let input) = envelope.command else {
      return errorResponse(code: CLIErrorCode.tabFailed, message: "Invalid command.")
    }

    if input.action == .close, input.selector.isNone {
      return errorResponse(
        code: CLIErrorCode.invalidArgument,
        message: "tab close requires an explicit target selector."
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
    case .create:
      return handleCreate(input: input, target: target)
    case .close:
      return handleClose(input: input, target: target)
    }
  }

  private func handleCreate(input: TabInput, target: TabResolvedTarget) -> CommandResponse {
    let path = normalizedAllowedPath(input.path, worktreePath: target.worktreePath)
    guard input.path == nil || path != nil else {
      return errorResponse(
        code: CLIErrorCode.pathNotAllowed,
        message: "Tab path must be inside the resolved worktree."
      )
    }

    guard let createdTarget = createTab(target, path) else {
      return errorResponse(code: CLIErrorCode.tabFailed, message: "Failed to create tab.")
    }
    return success(action: .create, target: createdTarget)
  }

  private func handleClose(input: TabInput, target: TabResolvedTarget) -> CommandResponse {
    guard closeTab(target, input.force) else {
      return errorResponse(code: CLIErrorCode.tabFailed, message: "Failed to close tab.")
    }
    return success(action: .close, target: target)
  }

  private func normalizedAllowedPath(_ path: String?, worktreePath: String) -> String? {
    guard let path else { return nil }
    let normalizedPath = normalize(path)
    let normalizedWorktree = normalize(worktreePath)
    guard normalizedPath == normalizedWorktree || normalizedPath.hasPrefix(normalizedWorktree + "/") else {
      return nil
    }
    return normalizedPath
  }

  private func normalize(_ path: String) -> String {
    URL(fileURLWithPath: path, isDirectory: true)
      .standardizedFileURL
      .path(percentEncoded: false)
      .trimmingTrailingSlash()
  }

  private func success(action: TabAction, target: TabResolvedTarget) -> CommandResponse {
    do {
      return try CommandResponse(
        ok: true,
        command: "tab",
        schemaVersion: "prowl.cli.tab.v1",
        data: RawJSON(encoding: TabCommandPayload(action: action, target: makePayloadTarget(from: target)))
      )
    } catch {
      return errorResponse(code: CLIErrorCode.tabFailed, message: "Failed to encode response.")
    }
  }

  private func makePayloadTarget(from target: TabResolvedTarget) -> TabTarget {
    TabTarget(from: target)
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
      command: "tab",
      schemaVersion: "prowl.cli.tab.v1",
      error: CommandError(code: code, message: message)
    )
  }
}

extension String {
  fileprivate func trimmingTrailingSlash() -> String {
    var value = self
    while value.count > 1, value.hasSuffix("/") {
      value.removeLast()
    }
    return value
  }
}
