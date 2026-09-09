import Foundation

/// A lease advertises a particular observation, not a lasting right to type.
/// Each source must re-observe immediately before committing bytes to its PTY.
nonisolated struct MirrorSubmissionReadiness {
  struct Observation: Equatable, Sendable {
    let generation: UUID?
    let runtimeRevision: UInt64
    let screenDigest: Data
    let lastEditingAt: TimeInterval?
    let refusal: String?
  }

  private var observation: Observation?
  private var stableSince: TimeInterval = 0
  private var revision: UInt64 = 0
  private var ready = false
  private var delivered: (generation: UUID, runtimeRevision: UInt64)?

  mutating func observe(_ current: Observation, now: TimeInterval) -> MirrorAgentState {
    guard now.isFinite, current.lastEditingAt?.isFinite != false else {
      observation = nil
      ready = false
      revision &+= 1
      return state(current, now: 0, canSubmit: false, reason: "Invalid observation time.")
    }
    if observation != current || now < stableSince {
      observation = current
      stableSince = now
      ready = false
      revision &+= 1
    }
    if let delivered,
      current.generation != delivered.generation || current.runtimeRevision > delivered.runtimeRevision
    {
      self.delivered = nil
    }
    let reason: String
    if current.generation == nil {
      reason = "Waiting for an identified Agent process."
    } else if let refusal = current.refusal {
      reason = refusal
    } else if delivered != nil {
      reason = "Waiting for the Agent to acknowledge the previous input."
    } else if now < stableSince + 2 || current.lastEditingAt.map({ now < $0 + 2 }) == true {
      reason = "Waiting for the Agent input to settle."
    } else {
      reason = "Ready to send."
      if !ready {
        revision &+= 1
        ready = true
      }
      return state(current, now: now, canSubmit: true, reason: reason)
    }
    if ready {
      revision &+= 1
      ready = false
    }
    return state(current, now: now, canSubmit: false, reason: reason)
  }

  mutating func claim(_ expected: MirrorAgentState) -> Bool {
    guard ready, expected.canSubmit, expected.revision == revision,
      let current = observation, let generation = current.generation, generation == expected.generation
    else { return false }
    delivered = (generation, current.runtimeRevision)
    ready = false
    revision &+= 1
    return true
  }

  private func state(
    _ observation: Observation, now: TimeInterval, canSubmit: Bool, reason: String
  ) -> MirrorAgentState {
    MirrorAgentState(
      generation: observation.generation, revision: revision, canSubmit: canSubmit,
      reason: reason, observedAt: now)
  }
}
