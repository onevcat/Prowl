// supacode/CLIService/KeyCommandHandler.swift
// Handles `prowl key` by resolving target, delivering key events, and building response.

import Foundation
import ProwlCLIShared

private let keyLogger = SupaLogger("KeyCommandHandler")

/// Result of delivering key events to a terminal pane.
struct KeyDeliveryResult: Sendable {
  let attempted: Int
  let delivered: Int
}

/// Resolved target metadata for key payload construction (no live view reference).
struct KeyResolvedTarget: Sendable {
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

extension KeyResolvedTarget {
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
final class KeyCommandHandler: CommandHandler {
  typealias ResolveProvider = @MainActor (TargetSelector) -> Result<KeyResolvedTarget, TargetResolverError>
  typealias KeyDeliveryProvider = @MainActor (KeyResolvedTarget, String, Int) -> KeyDeliveryResult

  private let resolveProvider: ResolveProvider
  private let keyDelivery: KeyDeliveryProvider

  init(
    resolveProvider: @escaping ResolveProvider,
    keyDelivery: @escaping KeyDeliveryProvider
  ) {
    self.resolveProvider = resolveProvider
    self.keyDelivery = keyDelivery
  }

  // swiftlint:disable:next async_without_await
  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    guard case .key(let input) = envelope.command else {
      return errorResponse(code: CLIErrorCode.keyDeliveryFailed, message: "Invalid command.")
    }

    // Validate token is supported
    guard let category = KeyTokens.category(for: input.token) else {
      return errorResponse(
        code: CLIErrorCode.unsupportedKey,
        message: "The key token '\(input.token)' is not supported."
      )
    }

    // Resolve target
    let target: KeyResolvedTarget
    switch resolveProvider(input.selector) {
    case .success(let resolved):
      target = resolved
    case .failure(let error):
      if input.selector == .none, case .notFound = error {
        return errorResponse(
          code: CLIErrorCode.noActivePane,
          message: "No active pane to receive key events."
        )
      }
      return mapResolverError(error)
    }

    // Deliver key events
    let result = keyDelivery(target, input.token, input.repeatCount)

    guard result.delivered == result.attempted else {
      return errorResponse(
        code: CLIErrorCode.keyDeliveryFailed,
        message: "Key delivery failed: \(result.delivered)/\(result.attempted) events delivered."
      )
    }

    // Build payload
    let payload = KeyCommandPayload(
      requested: KeyRequested(token: input.rawToken, repeat: input.repeatCount),
      key: KeyInfo(normalized: input.token, category: category),
      delivery: KeyDelivery(attempted: result.attempted, delivered: result.delivered),
      target: makePayloadTarget(from: target)
    )

    do {
      return try CommandResponse(
        ok: true,
        command: "key",
        schemaVersion: "prowl.cli.key.v1",
        data: RawJSON(encoding: payload)
      )
    } catch {
      keyLogger.warning("Failed to encode key payload: \(error)")
      return errorResponse(code: CLIErrorCode.keyDeliveryFailed, message: "Failed to encode response.")
    }
  }

  // MARK: - Helpers

  private func makePayloadTarget(from target: KeyResolvedTarget) -> KeyTarget {
    KeyTarget(
      worktree: KeyTargetWorktree(
        id: target.worktreeID,
        name: target.worktreeName,
        path: target.worktreePath,
        rootPath: target.worktreeRootPath,
        kind: target.worktreeKind.rawValue
      ),
      tab: KeyTargetTab(
        id: target.tabID.uuidString,
        title: target.tabTitle,
        selected: target.tabSelected
      ),
      pane: KeyTargetPane(
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
      command: "key",
      schemaVersion: "prowl.cli.key.v1",
      error: CommandError(code: code, message: message)
    )
  }
}
