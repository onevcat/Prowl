import Foundation
import ProwlCLIShared

nonisolated enum AgentDispatchRecord: Equatable, Sendable {
  case pending(id: String, createdAt: Date)
  case completed(
    id: String,
    outcome: DispatchCompletionOutcome,
    summary: String,
    createdAt: Date,
    completedAt: Date
  )
  case gone(id: String, createdAt: Date, goneAt: Date, reason: DispatchGoneReason)
  case abandoned(id: String, createdAt: Date, abandonedAt: Date, reason: String)

  var id: String {
    switch self {
    case .pending(let id, _),
      .completed(let id, _, _, _, _),
      .gone(let id, _, _, _),
      .abandoned(let id, _, _, _):
      id
    }
  }

  var state: DispatchRecordState {
    switch self {
    case .pending: .pending
    case .completed: .completed
    case .gone: .gone
    case .abandoned: .abandoned
    }
  }

  var createdAt: Date {
    switch self {
    case .pending(_, let createdAt),
      .completed(_, _, _, let createdAt, _),
      .gone(_, let createdAt, _, _),
      .abandoned(_, let createdAt, _, _):
      createdAt
    }
  }

  var isTerminal: Bool { state != .pending }
}

nonisolated struct AgentDispatchBinding: Equatable, Sendable {
  let surfaceID: UUID
  let target: TabTarget
  let evidenceEpoch: UUID
}

nonisolated struct AgentDispatchSnapshot: Equatable, Sendable {
  let record: AgentDispatchRecord
  let binding: AgentDispatchBinding?
}

extension AgentDispatchSnapshot {
  func payload(using formatter: ISO8601DateFormatter) -> DispatchRecordPayload {
    switch record {
    case .pending(let id, let createdAt):
      return .pending(DispatchPendingRecord(id: id, createdAt: formatter.string(from: createdAt)))
    case .completed(let id, let outcome, let summary, let createdAt, let completedAt):
      return .completed(
        DispatchCompletedRecord(
          id: id,
          outcome: outcome,
          summary: summary,
          createdAt: formatter.string(from: createdAt),
          completedAt: formatter.string(from: completedAt)
        ))
    case .gone(let id, let createdAt, let goneAt, let reason):
      return .gone(
        DispatchGoneRecord(
          id: id,
          createdAt: formatter.string(from: createdAt),
          goneAt: formatter.string(from: goneAt),
          reason: reason
        ))
    case .abandoned(let id, let createdAt, let abandonedAt, let reason):
      return .abandoned(
        DispatchAbandonedRecord(
          id: id,
          createdAt: formatter.string(from: createdAt),
          abandonedAt: formatter.string(from: abandonedAt),
          reason: reason
        ))
    }
  }
}

nonisolated struct AgentDispatchMutationResult: Equatable, Sendable {
  let snapshot: AgentDispatchSnapshot
  let replayed: Bool
}

nonisolated enum AgentDispatchTerminalEvidence: Equatable, Sendable {
  case turnEnded
  case sessionEnd
  case needsInput
}

nonisolated enum AgentDispatchObservation: Equatable, Sendable {
  case snapshot(AgentDispatchSnapshot)
  case changed(AgentDispatchSnapshot)
  case needsInput(AgentDispatchSnapshot)
  case incomplete(AgentDispatchSnapshot)
}

nonisolated enum AgentDispatchStoreError: Error, Equatable, Sendable {
  case capacityExceeded
  case notFound
  case bindingMissing
  case alreadyBound
  case sourceMismatch
  case alreadyCompleted
  case alreadyTerminal
  /// The surface already holds a pending record; a second one would let two assignments
  /// race for the same receipt.
  case surfacePending
}

typealias AgentDispatchObservationStream = AsyncStream<AgentDispatchObservation>

@MainActor
final class AgentDispatchStore {
  private struct Entry {
    var snapshot: AgentDispatchSnapshot
    var activeEvidence: AgentDispatchTerminalEvidence?
    var subscribers: [UUID: AgentDispatchObservationStream.Continuation] = [:]
  }

  private enum CandidateKind {
    case incomplete
    case gone(DispatchGoneReason)
  }

  private struct Candidate {
    let token: UUID
    var kind: CandidateKind
    let task: Task<Void, Never>
  }

  private let capacity: Int
  private let now: @MainActor () -> Date
  private let makeID: @MainActor () -> String
  private let coalescingClock: any Clock<Duration>
  private var entries: [String: Entry] = [:]
  private var issuanceOrder: [String] = []
  private var candidates: [String: Candidate] = [:]

  init(
    capacity: Int = 256,
    now: @escaping @MainActor () -> Date = Date.init,
    makeID: @escaping @MainActor () -> String = { UUID().uuidString },
    coalescingClock: any Clock<Duration> = ContinuousClock()
  ) {
    self.capacity = max(1, capacity)
    self.now = now
    self.makeID = makeID
    self.coalescingClock = coalescingClock
  }

  func issue() throws -> AgentDispatchSnapshot {
    if entries.count >= capacity {
      guard let terminalID = issuanceOrder.first(where: { entries[$0]?.snapshot.record.isTerminal == true }) else {
        throw AgentDispatchStoreError.capacityExceeded
      }
      remove(dispatchID: terminalID)
    }

    let dispatchID = makeID()
    precondition(entries[dispatchID] == nil, "Dispatch id generator returned a duplicate id")
    let snapshot = AgentDispatchSnapshot(
      record: .pending(id: dispatchID, createdAt: now()),
      binding: nil
    )
    entries[dispatchID] = Entry(snapshot: snapshot, activeEvidence: nil)
    issuanceOrder.append(dispatchID)
    return snapshot
  }

  func cancelIssuance(dispatchID: String) {
    guard let entry = entries[dispatchID], entry.snapshot.record.state == .pending else { return }
    remove(dispatchID: dispatchID)
  }

  func bind(dispatchID: String, binding: AgentDispatchBinding) throws {
    guard var entry = entries[dispatchID] else { throw AgentDispatchStoreError.notFound }
    guard entry.snapshot.record.state == .pending else { throw AgentDispatchStoreError.alreadyTerminal }
    if let existing = entry.snapshot.binding {
      guard existing == binding else { throw AgentDispatchStoreError.alreadyBound }
      return
    }
    guard pendingDispatchID(surfaceID: binding.surfaceID) == nil else {
      throw AgentDispatchStoreError.surfacePending
    }
    entry.snapshot = AgentDispatchSnapshot(record: entry.snapshot.record, binding: binding)
    entries[dispatchID] = entry
  }

  func snapshot(dispatchID: String) -> AgentDispatchSnapshot? {
    entries[dispatchID]?.snapshot
  }

  /// The one pending record bound to the surface, if any.
  func pendingSnapshot(surfaceID: UUID) -> AgentDispatchSnapshot? {
    pendingDispatchID(surfaceID: surfaceID).flatMap { entries[$0]?.snapshot }
  }

  /// Completes the caller pane's current pending record. Without one, the pane's most
  /// recently issued record answers instead so an identical retry replays its receipt and
  /// a conflicting one is rejected exactly as an id-addressed completion would be.
  func complete(
    surfaceID: UUID,
    outcome: DispatchCompletionOutcome,
    summary: String
  ) throws -> AgentDispatchMutationResult {
    guard let dispatchID = pendingDispatchID(surfaceID: surfaceID) ?? latestDispatchID(surfaceID: surfaceID)
    else { throw AgentDispatchStoreError.notFound }
    return try complete(dispatchID: dispatchID, outcome: outcome, summary: summary, callerSurfaceID: surfaceID)
  }

  private func pendingDispatchID(surfaceID: UUID) -> String? {
    issuanceOrder.first { dispatchID in
      guard let entry = entries[dispatchID] else { return false }
      return entry.snapshot.record.state == .pending && entry.snapshot.binding?.surfaceID == surfaceID
    }
  }

  private func latestDispatchID(surfaceID: UUID) -> String? {
    issuanceOrder.last { entries[$0]?.snapshot.binding?.surfaceID == surfaceID }
  }

  func complete(
    dispatchID: String,
    outcome: DispatchCompletionOutcome,
    summary: String,
    callerSurfaceID: UUID
  ) throws -> AgentDispatchMutationResult {
    guard var entry = entries[dispatchID] else { throw AgentDispatchStoreError.notFound }
    guard let binding = entry.snapshot.binding else { throw AgentDispatchStoreError.bindingMissing }
    guard binding.surfaceID == callerSurfaceID else { throw AgentDispatchStoreError.sourceMismatch }

    switch entry.snapshot.record {
    case .pending(let id, let createdAt):
      cancelCandidate(dispatchID: dispatchID)
      entry.snapshot = AgentDispatchSnapshot(
        record: .completed(
          id: id,
          outcome: outcome,
          summary: summary,
          createdAt: createdAt,
          completedAt: now()
        ),
        binding: binding
      )
      entry.activeEvidence = nil
      entries[dispatchID] = entry
      publishTerminal(entry.snapshot, dispatchID: dispatchID)
      return AgentDispatchMutationResult(snapshot: entry.snapshot, replayed: false)
    case .completed(_, let existingOutcome, let existingSummary, _, _):
      guard existingOutcome == outcome, existingSummary == summary else {
        throw AgentDispatchStoreError.alreadyCompleted
      }
      return AgentDispatchMutationResult(snapshot: entry.snapshot, replayed: true)
    case .gone, .abandoned:
      throw AgentDispatchStoreError.alreadyTerminal
    }
  }

  func abandon(dispatchID: String, reason: String) throws -> AgentDispatchMutationResult {
    guard var entry = entries[dispatchID] else { throw AgentDispatchStoreError.notFound }
    switch entry.snapshot.record {
    case .pending(let id, let createdAt):
      cancelCandidate(dispatchID: dispatchID)
      entry.snapshot = AgentDispatchSnapshot(
        record: .abandoned(
          id: id,
          createdAt: createdAt,
          abandonedAt: now(),
          reason: reason
        ),
        binding: entry.snapshot.binding
      )
      entry.activeEvidence = nil
      entries[dispatchID] = entry
      publishTerminal(entry.snapshot, dispatchID: dispatchID)
      return AgentDispatchMutationResult(snapshot: entry.snapshot, replayed: false)
    case .abandoned(_, _, _, let existingReason) where existingReason == reason:
      return AgentDispatchMutationResult(snapshot: entry.snapshot, replayed: true)
    case .completed, .gone, .abandoned:
      throw AgentDispatchStoreError.alreadyTerminal
    }
  }

  func observe(dispatchID: String) throws -> AgentDispatchObservationStream {
    guard var entry = entries[dispatchID] else { throw AgentDispatchStoreError.notFound }
    let initial = entry.snapshot
    if initial.record.isTerminal {
      return AgentDispatchObservationStream { continuation in
        continuation.yield(.snapshot(initial))
        continuation.finish()
      }
    }

    let subscriberID = UUID()
    var captured: AgentDispatchObservationStream.Continuation?
    let stream = AgentDispatchObservationStream { captured = $0 }
    guard let continuation = captured else { return stream }
    continuation.onTermination = { @Sendable [weak self] _ in
      Task { @MainActor [weak self] in
        self?.removeSubscriber(subscriberID, dispatchID: dispatchID)
      }
    }
    entry.subscribers[subscriberID] = continuation
    entries[dispatchID] = entry
    switch entry.activeEvidence {
    case .needsInput:
      continuation.yield(.needsInput(initial))
    case .turnEnded:
      continuation.yield(.incomplete(initial))
    case .sessionEnd, nil:
      continuation.yield(.snapshot(initial))
    }
    return stream
  }

  func subscriberCount(dispatchID: String) -> Int {
    entries[dispatchID]?.subscribers.count ?? 0
  }

  func noteTerminalEvidence(dispatchID: String, evidence: AgentDispatchTerminalEvidence) {
    guard entries[dispatchID]?.snapshot.record.state == .pending else { return }
    switch evidence {
    case .needsInput:
      cancelIncompleteCandidate(dispatchID: dispatchID)
      entries[dispatchID]?.activeEvidence = .needsInput
      if let snapshot = entries[dispatchID]?.snapshot {
        publish(.needsInput(snapshot), dispatchID: dispatchID)
      }
    case .turnEnded:
      scheduleCandidate(dispatchID: dispatchID, kind: .incomplete)
    case .sessionEnd:
      entries[dispatchID]?.activeEvidence = nil
      scheduleCandidate(dispatchID: dispatchID, kind: .gone(.sessionEnd))
    }
  }

  func noteActivity(surfaceID: UUID, evidenceEpoch: UUID) {
    let dispatchIDs = entries.compactMap { dispatchID, entry in
      entry.snapshot.record.state == .pending
        && entry.snapshot.binding?.surfaceID == surfaceID
        && entry.snapshot.binding?.evidenceEpoch == evidenceEpoch
        ? dispatchID : nil
    }
    for dispatchID in dispatchIDs {
      cancelIncompleteCandidate(dispatchID: dispatchID)
      entries[dispatchID]?.activeEvidence = nil
    }
  }

  func noteTerminalEvidence(
    surfaceID: UUID,
    evidenceEpoch: UUID,
    evidence: AgentDispatchTerminalEvidence
  ) {
    let dispatchIDs = entries.compactMap { dispatchID, entry in
      entry.snapshot.record.state == .pending
        && entry.snapshot.binding?.surfaceID == surfaceID
        && entry.snapshot.binding?.evidenceEpoch == evidenceEpoch
        ? dispatchID : nil
    }
    for dispatchID in dispatchIDs {
      noteTerminalEvidence(dispatchID: dispatchID, evidence: evidence)
    }
  }

  func surfaceClosed(surfaceID: UUID) {
    let dispatchIDs = entries.compactMap { dispatchID, entry in
      entry.snapshot.record.state == .pending && entry.snapshot.binding?.surfaceID == surfaceID
        ? dispatchID : nil
    }
    for dispatchID in dispatchIDs {
      scheduleCandidate(dispatchID: dispatchID, kind: .gone(.surfaceClosed))
    }
  }

  private func scheduleCandidate(dispatchID: String, kind: CandidateKind) {
    if var existing = candidates[dispatchID] {
      if case .incomplete = existing.kind, case .gone = kind {
        existing.kind = kind
        candidates[dispatchID] = existing
      }
      return
    }

    let token = UUID()
    let clock = coalescingClock
    let task = Task { @MainActor [weak self] in
      do {
        try await clock.sleep(for: .milliseconds(300))
      } catch {
        return
      }
      self?.commitCandidate(dispatchID: dispatchID, token: token)
    }
    candidates[dispatchID] = Candidate(token: token, kind: kind, task: task)
  }

  private func commitCandidate(dispatchID: String, token: UUID) {
    guard let candidate = candidates[dispatchID], candidate.token == token else { return }
    candidates.removeValue(forKey: dispatchID)
    guard var entry = entries[dispatchID] else { return }
    guard case .pending(let id, let createdAt) = entry.snapshot.record else { return }

    switch candidate.kind {
    case .incomplete:
      entry.activeEvidence = .turnEnded
      entries[dispatchID] = entry
      publish(.incomplete(entry.snapshot), dispatchID: dispatchID)
    case .gone(let reason):
      entry.snapshot = AgentDispatchSnapshot(
        record: .gone(id: id, createdAt: createdAt, goneAt: now(), reason: reason),
        binding: entry.snapshot.binding
      )
      entries[dispatchID] = entry
      publishTerminal(entry.snapshot, dispatchID: dispatchID)
    }
  }

  private func publish(_ event: AgentDispatchObservation, dispatchID: String) {
    guard let subscribers = entries[dispatchID]?.subscribers else { return }
    for continuation in subscribers.values {
      continuation.yield(event)
    }
  }

  private func publishTerminal(_ snapshot: AgentDispatchSnapshot, dispatchID: String) {
    guard var entry = entries[dispatchID] else { return }
    let subscribers = entry.subscribers.values
    entry.subscribers.removeAll()
    entries[dispatchID] = entry
    for continuation in subscribers {
      continuation.yield(.changed(snapshot))
      continuation.finish()
    }
  }

  private func cancelCandidate(dispatchID: String) {
    candidates.removeValue(forKey: dispatchID)?.task.cancel()
  }

  private func cancelIncompleteCandidate(dispatchID: String) {
    guard let candidate = candidates[dispatchID], case .incomplete = candidate.kind else { return }
    candidates.removeValue(forKey: dispatchID)?.task.cancel()
  }

  private func removeSubscriber(_ subscriberID: UUID, dispatchID: String) {
    guard var entry = entries[dispatchID] else { return }
    entry.subscribers.removeValue(forKey: subscriberID)
    entries[dispatchID] = entry
  }

  private func remove(dispatchID: String) {
    cancelCandidate(dispatchID: dispatchID)
    if let entry = entries.removeValue(forKey: dispatchID) {
      for continuation in entry.subscribers.values {
        continuation.finish()
      }
    }
    issuanceOrder.removeAll { $0 == dispatchID }
  }
}
