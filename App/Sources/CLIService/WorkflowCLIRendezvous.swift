// supacode/CLIService/WorkflowCLIRendezvous.swift
// The request/response seam between a socket handler and the workflow reducer (docs-ai 063 B3,
// decision W1). It owns continuations only, never run state: the handler registers a request,
// sends the reducer action, then awaits; the reducer resolves when the command's declared
// response point is reached. Everything is main-actor serialized, so a reducer that answers
// synchronously inside `store.send` cannot race past the waiter — the answer is buffered.

import Foundation
import ProwlCLIShared

@MainActor
final class WorkflowCLIRendezvous {
  private enum Slot {
    case registered
    case buffered(CommandResponse)
    case waiting(CheckedContinuation<CommandResponse, Never>)
  }

  private var slots: [UUID: Slot] = [:]

  var pendingRequestIDs: Set<UUID> { Set(slots.keys) }

  /// Claims a request id before the reducer action is sent. False when the id is already in use.
  @discardableResult
  func register(_ requestID: UUID) -> Bool {
    guard slots[requestID] == nil else { return false }
    slots[requestID] = .registered
    return true
  }

  /// Awaits the response of a registered request; an answer that arrived before the wait is
  /// returned at once. Cancelling the waiting task (the socket peer disconnected) releases the
  /// slot with `REQUEST_CANCELLED` without touching the run.
  func wait(for requestID: UUID) async -> CommandResponse {
    switch slots[requestID] {
    case .none:
      return Self.failure(code: CLIErrorCode.requestConflict, message: "Workflow request was not registered.")
    case .waiting:
      return Self.failure(code: CLIErrorCode.requestConflict, message: "Workflow request is already pending.")
    case .buffered(let response):
      slots.removeValue(forKey: requestID)
      return response
    case .registered:
      break
    }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        switch slots[requestID] {
        case .buffered(let response):
          // Resolved (or cancelled) between the synchronous check above and this suspension.
          slots.removeValue(forKey: requestID)
          continuation.resume(returning: response)
        case .registered:
          slots[requestID] = .waiting(continuation)
        case .none, .waiting:
          continuation.resume(
            returning: Self.failure(code: CLIErrorCode.requestConflict, message: "Workflow request is already pending.")
          )
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancel(requestID)
      }
    }
  }

  /// Delivers the response; false when no request with this id is outstanding.
  @discardableResult
  func resolve(_ requestID: UUID, with response: CommandResponse) -> Bool {
    switch slots[requestID] {
    case .none, .buffered:
      return false
    case .registered:
      slots[requestID] = .buffered(response)
      return true
    case .waiting(let continuation):
      slots.removeValue(forKey: requestID)
      continuation.resume(returning: response)
      return true
    }
  }

  /// Socket routing cancellation never changes the run: it merely releases this caller's
  /// continuation. The reducer continues the already-accepted transaction.
  @discardableResult
  func cancel(_ requestID: UUID) -> Bool {
    resolve(
      requestID,
      with: Self.failure(code: CLIErrorCode.requestCancelled, message: "Workflow command request was cancelled.")
    )
  }

  static func failure(code: String, message: String) -> CommandResponse {
    CommandResponse(
      ok: false,
      command: WorkflowCommandPayload.commandName,
      schemaVersion: WorkflowCommandPayload.schemaVersion,
      error: CommandError(code: code, message: message)
    )
  }
}
