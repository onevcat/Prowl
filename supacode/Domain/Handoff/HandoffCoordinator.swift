import Foundation

/// Shared persistence boundary for `builtin:save-handoff`. Workflow admission,
/// receiver launch, and history remain outside this artifact writer.
nonisolated struct HandoffCoordinator: Sendable {
  let store: HandoffStore

  /// The workflow action validates `briefing` before this irreversible write.
  func makeCheckpoint(
    outgoingAgent: String?,
    sessionContext: HandoffStore.SessionContext?,
    note: String?,
    briefing: String,
    now: Date
  ) async throws -> HandoffStore.SaveResult {
    let store = self.store
    return try await Task.detached {
      try store.writeBriefing(briefing, now: now)
      return try store.save(
        outgoingAgent: outgoingAgent,
        sessionContext: sessionContext,
        note: note,
        now: now
      )
    }.value
  }
}
