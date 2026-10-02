// supacode/Clients/Workflow/WorkflowEffectQueueClient.swift
// One FIFO per run for the machine's ordered effects (docs-ai 063 B3). The reducer enqueues
// every batch synchronously as it reduces; a single long-lived effect per run performs them one
// after another, so an instruction file exists before the line that names it is typed and
// `run.json` writes never overtake each other. Long-running observers (idle waits, watchdogs)
// stay separate cancellable effects. A *fence* invalidates everything enqueued before it: the
// reducer raises one whenever a revoke or the run's end makes earlier queued work stale, and the
// executor drops such work effect by effect instead of typing into a pane a cancel already left.

import ComposableArchitecture
import Foundation

/// A batch of effects together with the run state they were emitted from (`persist` writes it).
struct WorkflowEffectBatch: Equatable, Sendable {
  /// Enqueue order within the run; the queue assigns it.
  var sequence: Int = 0
  let session: WorkflowRunSession
  let effects: [WorkflowRunEffect]

  init(session: WorkflowRunSession, effects: [WorkflowRunEffect]) {
    self.session = session
    self.effects = effects
  }
}

struct WorkflowEffectQueueClient: Sendable {
  /// Opens the run's queue; the stream ends after `finish`.
  var start: @MainActor @Sendable (UUID) -> AsyncStream<WorkflowEffectBatch>
  var enqueue: @MainActor @Sendable (UUID, WorkflowEffectBatch) -> Void
  /// Marks every batch enqueued so far as stale.
  var fence: @MainActor @Sendable (UUID) -> Void
  /// Whether a batch with this sequence was fenced after it was enqueued.
  var isStale: @MainActor @Sendable (UUID, Int) -> Bool
  var finish: @MainActor @Sendable (UUID) -> Void
}

@MainActor
final class WorkflowEffectQueue {
  private struct Lane {
    var continuation: AsyncStream<WorkflowEffectBatch>.Continuation
    var nextSequence = 1
    /// Batches with a sequence at or below this were enqueued before the latest fence.
    var fencedThrough = 0
  }

  private var lanes: [UUID: Lane] = [:]

  func start(_ runID: UUID) -> AsyncStream<WorkflowEffectBatch> {
    lanes[runID]?.continuation.finish()
    let (stream, continuation) = AsyncStream.makeStream(of: WorkflowEffectBatch.self)
    lanes[runID] = Lane(continuation: continuation)
    return stream
  }

  func enqueue(_ runID: UUID, _ batch: WorkflowEffectBatch) {
    guard var lane = lanes[runID] else { return }
    var sequenced = batch
    sequenced.sequence = lane.nextSequence
    lane.nextSequence += 1
    lanes[runID] = lane
    lane.continuation.yield(sequenced)
  }

  func fence(_ runID: UUID) {
    guard var lane = lanes[runID] else { return }
    lane.fencedThrough = lane.nextSequence - 1
    lanes[runID] = lane
  }

  func isStale(_ runID: UUID, sequence: Int) -> Bool {
    guard let lane = lanes[runID] else { return true }
    return sequence <= lane.fencedThrough
  }

  func finish(_ runID: UUID) {
    lanes.removeValue(forKey: runID)?.continuation.finish()
  }

  var client: WorkflowEffectQueueClient {
    WorkflowEffectQueueClient(
      start: { [self] runID in start(runID) },
      enqueue: { [self] runID, batch in enqueue(runID, batch) },
      fence: { [self] runID in fence(runID) },
      isStale: { [self] runID, sequence in isStale(runID, sequence: sequence) },
      finish: { [self] runID in finish(runID) }
    )
  }
}

extension WorkflowEffectQueueClient: DependencyKey {
  /// The app installs `WorkflowEffectQueue().client` at its composition root; tests inject a
  /// queue explicitly. The default performs nothing.
  static let liveValue = WorkflowEffectQueueClient(
    start: { _ in AsyncStream { $0.finish() } },
    enqueue: { _, _ in },
    fence: { _ in },
    isStale: { _, _ in false },
    finish: { _ in }
  )

  static let testValue = liveValue
}

extension DependencyValues {
  var workflowEffectQueue: WorkflowEffectQueueClient {
    get { self[WorkflowEffectQueueClient.self] }
    set { self[WorkflowEffectQueueClient.self] = newValue }
  }
}
