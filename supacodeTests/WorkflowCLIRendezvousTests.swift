import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct WorkflowCLIRendezvousTests {
  @Test func responseResumesTheRegisteredRequest() async {
    let rendezvous = WorkflowCLIRendezvous()
    let requestID = UUID()
    #expect(rendezvous.register(requestID))
    let task = Task { @MainActor in
      await rendezvous.wait(for: requestID)
    }

    await Task.yield()
    #expect(rendezvous.resolve(requestID, with: Self.successResponse))

    let response = await task.value
    #expect(response.ok)
    #expect(rendezvous.pendingRequestIDs.isEmpty)
  }

  /// The reducer answers inside `store.send`, before the handler reaches its `await`: the
  /// answer is buffered on the registered slot instead of being lost.
  @Test func aResponseThatArrivesBeforeTheWaitIsBufferedAndReturnedAtOnce() async {
    let rendezvous = WorkflowCLIRendezvous()
    let requestID = UUID()
    rendezvous.register(requestID)
    #expect(rendezvous.resolve(requestID, with: Self.successResponse))
    #expect(rendezvous.pendingRequestIDs == [requestID])

    let response = await rendezvous.wait(for: requestID)
    #expect(response.ok)
    #expect(rendezvous.pendingRequestIDs.isEmpty)
    #expect(!rendezvous.resolve(requestID, with: Self.successResponse))
  }

  @Test func cancellingPendingRequestResumesItWithCancellationResponse() async {
    let rendezvous = WorkflowCLIRendezvous()
    let requestID = UUID()
    rendezvous.register(requestID)
    let task = Task { @MainActor in
      await rendezvous.wait(for: requestID)
    }

    await Task.yield()
    #expect(rendezvous.cancel(requestID))

    let response = await task.value
    #expect(!response.ok)
    #expect(response.error?.code == CLIErrorCode.requestCancelled)
    #expect(rendezvous.pendingRequestIDs.isEmpty)
    // A late reducer answer finds nothing to resolve and changes nothing.
    #expect(!rendezvous.resolve(requestID, with: Self.successResponse))
  }

  @Test func cancellingTheWaitingTaskReleasesTheSlotWithoutTouchingTheRun() async {
    let rendezvous = WorkflowCLIRendezvous()
    let requestID = UUID()
    rendezvous.register(requestID)
    let task = Task { @MainActor in
      await rendezvous.wait(for: requestID)
    }
    await Task.yield()
    task.cancel()
    let response = await task.value
    #expect(response.error?.code == CLIErrorCode.requestCancelled)
    #expect(rendezvous.pendingRequestIDs.isEmpty)
  }

  @Test func duplicateRequestIDDoesNotReplaceTheOriginalWaiter() async {
    let rendezvous = WorkflowCLIRendezvous()
    let requestID = UUID()
    #expect(rendezvous.register(requestID))
    #expect(!rendezvous.register(requestID))
    let first = Task { @MainActor in await rendezvous.wait(for: requestID) }

    await Task.yield()
    let duplicate = await rendezvous.wait(for: requestID)
    #expect(!duplicate.ok)
    #expect(duplicate.error?.code == CLIErrorCode.requestConflict)

    #expect(rendezvous.resolve(requestID, with: Self.successResponse))
    #expect((await first.value).ok)
  }

  @Test func waitingWithoutRegistrationFailsInsteadOfHanging() async {
    let rendezvous = WorkflowCLIRendezvous()
    let response = await rendezvous.wait(for: UUID())
    #expect(response.error?.code == CLIErrorCode.requestConflict)
  }

  private static let successResponse = CommandResponse(
    ok: true,
    command: WorkflowCommandPayload.commandName,
    schemaVersion: WorkflowCommandPayload.schemaVersion
  )
}
