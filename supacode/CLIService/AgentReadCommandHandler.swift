import Foundation
import ProwlCLIShared

nonisolated struct AgentReadRuntimeSnapshot: Sendable {
  let target: ReadTarget
  let agent: DetectedAgent
  let status: AgentsCommandStatus
  let rawState: String
  let detectionReason: String?
  let lastChangedAt: String
  let blockerText: String?
  /// Only an exact/high, transcript-backed fresh resolution belongs here.
  let transcriptSession: AgentSession?
}

nonisolated enum AgentReadSnapshotError: Error, Sendable {
  case targetNotFound(String)
  case agentNotFound(String)
  case unsupportedAgent(String)
  case activeScreenUnreadable
  case blockerUnreadable
}

@MainActor
final class AgentReadCommandHandler: CommandHandler {
  typealias SnapshotProvider = @MainActor (String) async -> Result<AgentReadRuntimeSnapshot, AgentReadSnapshotError>
  typealias ResultProvider = @Sendable (DetectedAgent, URL, Int) async -> AgentTranscriptResult

  private let snapshotProvider: SnapshotProvider
  private let resultProvider: ResultProvider

  init(
    snapshotProvider: @escaping SnapshotProvider,
    resultProvider: @escaping ResultProvider
  ) {
    self.snapshotProvider = snapshotProvider
    self.resultProvider = resultProvider
  }

  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    guard case .agentsRead(let input) = envelope.command else {
      return errorResponse(code: CLIErrorCode.agentReadFailed, message: "Invalid command.")
    }
    guard (1...AgentReadInput.maximumMaxBytes).contains(input.maxBytes) else {
      return errorResponse(
        code: CLIErrorCode.invalidArgument,
        message: "--max-bytes must be between 1 and \(AgentReadInput.maximumMaxBytes)."
      )
    }

    let snapshot: AgentReadRuntimeSnapshot
    switch await snapshotProvider(input.pane) {
    case .success(let resolved):
      snapshot = resolved
    case .failure(let error):
      return mapSnapshotError(error)
    }

    let result = await makeResult(from: snapshot, maxBytes: input.maxBytes)
    if input.resultOnly, result.state != .complete {
      let error = result.error ?? error(for: result.state)
      return errorResponse(code: error.code, message: error.message)
    }

    let payload = AgentReadCommandPayload(
      outputMode: input.resultOnly ? .resultOnly : .snapshot,
      target: snapshot.target,
      agent: AgentReadAgent(
        type: snapshot.agent.rawValue,
        status: snapshot.status,
        rawState: snapshot.rawState,
        detectionReason: snapshot.detectionReason,
        lastChangedAt: snapshot.lastChangedAt,
        session: snapshot.transcriptSession.map {
          AgentReadSession(id: $0.id, confidence: $0.confidence.rawValue, source: $0.source.rawValue)
        }
      ),
      blocker: snapshot.blockerText.map(AgentReadBlocker.init(text:)),
      result: result
    )

    do {
      return try CommandResponse(
        ok: true,
        command: "agents.read",
        schemaVersion: "prowl.cli.agents.read.v1",
        data: RawJSON(encoding: payload)
      )
    } catch {
      return errorResponse(code: CLIErrorCode.agentReadFailed, message: "Failed to encode agent snapshot.")
    }
  }

  private func makeResult(from snapshot: AgentReadRuntimeSnapshot, maxBytes: Int) async -> AgentReadResult {
    // A live turn owns the result slot: the transcript's last complete answer belongs to an
    // earlier turn and must not be mistaken for this one, and an unresolved session is not
    // yet a defect while the agent is still working.
    switch snapshot.status {
    case .working, .blocked:
      return AgentReadResult(state: .pending)
    case .idle, .done:
      break
    }
    guard let session = snapshot.transcriptSession, let path = session.transcriptPath else {
      return failedResult(.unavailable)
    }

    let transcript = await resultProvider(snapshot.agent, path, maxBytes)
    switch transcript.state {
    case .complete:
      guard let text = transcript.text else { return failedResult(.incomplete) }
      return AgentReadResult(state: .complete, text: text)
    case .missing:
      return failedResult(.missing)
    case .incomplete:
      return failedResult(.incomplete)
    case .tooLarge:
      return failedResult(.tooLarge)
    }
  }

  private func failedResult(_ state: AgentReadResultState) -> AgentReadResult {
    AgentReadResult(state: state, error: error(for: state))
  }

  private func error(for state: AgentReadResultState) -> AgentReadResultError {
    switch state {
    case .complete:
      AgentReadResultError(code: CLIErrorCode.agentReadFailed, message: "Missing complete agent result.")
    case .pending, .missing:
      AgentReadResultError(code: CLIErrorCode.resultNotFound, message: "No completed agent result is available.")
    case .unavailable:
      AgentReadResultError(
        code: CLIErrorCode.sessionUnresolved,
        message: "No exact or high-confidence transcript session is available."
      )
    case .incomplete:
      AgentReadResultError(
        code: CLIErrorCode.resultIncomplete,
        message: "The latest agent result is incomplete or unsupported."
      )
    case .tooLarge:
      AgentReadResultError(
        code: CLIErrorCode.resultTooLarge,
        message: "The latest agent result exceeds --max-bytes."
      )
    }
  }

  private func mapSnapshotError(_ error: AgentReadSnapshotError) -> CommandResponse {
    switch error {
    case .targetNotFound(let message):
      errorResponse(code: CLIErrorCode.targetNotFound, message: message)
    case .agentNotFound(let message):
      errorResponse(code: CLIErrorCode.agentNotFound, message: message)
    case .unsupportedAgent(let message):
      errorResponse(code: CLIErrorCode.agentUnsupported, message: message)
    case .activeScreenUnreadable:
      errorResponse(code: CLIErrorCode.agentReadFailed, message: "Failed to read the agent's active screen.")
    case .blockerUnreadable:
      errorResponse(code: CLIErrorCode.blockerUnreadable, message: "Failed to read the current agent blocker.")
    }
  }

  private func errorResponse(code: String, message: String) -> CommandResponse {
    CommandResponse(
      ok: false,
      command: "agents.read",
      schemaVersion: "prowl.cli.agents.read.v1",
      error: CommandError(code: code, message: message)
    )
  }
}
