import Foundation

/// The receiving launch configuration selected by the user. Runtime-default
/// targets preserve the existing inherited-configuration behavior; profiles
/// resolve their complete launch configuration by stable ID at execution.
nonisolated enum HandoffReceivingTarget: Equatable, Hashable, Sendable {
  case runtimeDefault(DetectedAgent)
  case profile(AgentProfile.ID)
}

/// The exact operation authorized by one HUD request. A handoff operation
/// always launches its receiver; an injected `--no-launch` request therefore
/// cannot satisfy a handoff expectation.
nonisolated enum HandoffRequestOperation: Equatable, Hashable, Sendable {
  case checkpoint
  case handoff(target: HandoffReceivingTarget)
}

/// Immutable facts captured when the HUD injects a request. The source pane is
/// part of the authorization, not merely completion metadata: the same request
/// UUID cannot be replayed from another pane.
nonisolated struct HandoffRequestExpectation: Equatable, Hashable, Sendable {
  let sourcePaneID: UUID
  let operation: HandoffRequestOperation
}

nonisolated enum HandoffRequestClaimResult: Equatable, Sendable {
  case claimed
  /// The request is still pending, but the submitted pane or operation does
  /// not match. A later exact submission may still claim it.
  case mismatch
  /// Unknown, already claimed, or superseded requests are intentionally
  /// indistinguishable to callers.
  case unavailable
}

/// Owns the one-shot authorization for a HUD-injected handoff request. The
/// HUD and socket handler both run on the main actor, so claiming the request
/// or superseding it for a fallback is one serialized state transition.
@MainActor
final class HandoffRequestRegistry {
  private enum State {
    case pending(HandoffRequestExpectation)
    case claimed
    case superseded
  }

  private var states: [UUID: State] = [:]

  func register(_ requestID: UUID, expectation: HandoffRequestExpectation) {
    // A UUID is one-shot for the registry's whole lifetime. In particular, a
    // duplicate registration cannot reopen a claimed or superseded request.
    guard states[requestID] == nil else { return }
    states[requestID] = .pending(expectation)
  }

  /// Claims only an exact pending request. A mismatch deliberately leaves the
  /// expectation pending so a malformed or stale submission cannot consume
  /// the user's authorized transition.
  @discardableResult
  func claim(
    _ requestID: UUID,
    actual: HandoffRequestExpectation
  ) -> HandoffRequestClaimResult {
    guard let state = states[requestID] else { return .unavailable }
    guard case .pending(let expected) = state else { return .unavailable }
    guard expected == actual else { return .mismatch }
    states[requestID] = .claimed
    return .claimed
  }

  /// Supersedes a still-pending injected request before the HUD begins its
  /// independent fallback transition. A handler that already claimed it owns
  /// the transition and must be allowed to finish instead.
  @discardableResult
  func supersede(_ requestID: UUID) -> Bool {
    guard case .pending = states[requestID] else { return false }
    states[requestID] = .superseded
    return true
  }
}
