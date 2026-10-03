import Foundation
import ProwlCLIShared

nonisolated struct AgentProcessGeneration: Equatable, Hashable, Sendable {
  let pid: pid_t
  let startedAt: Date
}

struct AgentSignal: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case turnEnded
    case needsInput
    case sessionStart
    case sessionEnd
    case progress(Int?)
  }

  enum Source: Equatable, Sendable {
    case cooperativeCLI
    case hook(runtime: AgentProfileRuntime, event: String)
    case transcript
    case process
    case osc
    case screen
  }

  enum Confidence: String, Equatable, Sendable {
    case exact
    case high
    case heuristic
  }

  let kind: Kind
  let source: Source
  let confidence: Confidence
  let timestamp: Date
  let sessionID: String?
  let detail: String?
  /// Caller-authored provenance hint. It never upgrades `source` or `confidence`.
  let claimedOrigin: String?
}

struct AgentObservationSnapshot: Equatable, Sendable {
  let agent: ActiveAgentEntry?
  let latestSignal: AgentSignal?
  /// Monotonic within one live surface. Consumers use it to recognize a newer
  /// resubscription snapshot after an overflow; it is not a persisted cursor.
  /// A synthetic snapshot for an already-closed surface resets to zero, and the
  /// following `surfaceClosed` event is authoritative.
  let revision: UInt64
}

enum ObservedAgentState: Equatable, Sendable {
  case snapshot(AgentObservationSnapshot)
  case changed(ActiveAgentEntry)
  case removed
  case signal(AgentSignal)
  case surfaceClosed
}

enum AgentObservationError: Error, Equatable, Sendable {
  case bufferOverflow
}

typealias AgentObservationStream = AsyncThrowingStream<ObservedAgentState, Error>

extension AgentSignal {
  var event: AgentSignalEvent {
    switch kind {
    case .turnEnded: .turnEnded
    case .needsInput: .needsInput
    case .sessionStart: .sessionStart
    case .sessionEnd: .sessionEnd
    case .progress: .progress
    }
  }

  var progress: Int? {
    guard case .progress(let value) = kind else { return nil }
    return value
  }

  func payload(timestamp: String) -> AgentSignalPayload {
    AgentSignalPayload(
      event: event,
      progress: progress,
      source: source.payloadName,
      confidence: confidence.rawValue,
      timestamp: timestamp,
      sessionID: sessionID,
      detail: detail,
      claimedOrigin: claimedOrigin
    )
  }
}

extension AgentSignal.Source {
  var payloadName: String {
    switch self {
    case .cooperativeCLI: "cooperative_cli"
    case .hook(let runtime, _): "hook_\(runtime.rawValue)"
    case .transcript: "transcript"
    case .process: "process"
    case .osc: "osc"
    case .screen: "screen"
    }
  }
}
