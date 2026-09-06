import Foundation
import ProwlCLIShared

/// What the app did with a cooperative signal from a live caller pane.
nonisolated enum AgentSignalRecordOutcome: Equatable, Sendable {
  case recorded(binding: AgentSignalBinding)
  case paneGone
}

@MainActor
final class AgentSignalCommandHandler: CommandHandler {
  typealias ResolveCaller = @MainActor (pid_t) -> CallerPane?
  typealias RecordSignal = @MainActor (CallerPane, AgentSignal) -> AgentSignalRecordOutcome

  private let resolveCaller: ResolveCaller
  private let recordSignal: RecordSignal
  private let now: @Sendable () -> Date
  private let dateFormatter: ISO8601DateFormatter

  init(
    resolveCaller: @escaping ResolveCaller,
    recordSignal: @escaping RecordSignal,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.resolveCaller = resolveCaller
    self.recordSignal = recordSignal
    self.now = now
    self.dateFormatter = ISO8601DateFormatter()
    self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
  }

  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    await handle(envelope: envelope, context: CLICommandContext())
  }

  // swiftlint:disable async_without_await
  func handle(
    envelope: CommandEnvelope,
    context: CLICommandContext
  ) async -> CommandResponse {
    guard case .agentsSignal(let input) = envelope.command else {
      return failure(code: CLIErrorCode.invalidArgument, message: "Expected an agents.signal command.")
    }
    if let validationMessage = input.validationErrorMessage {
      return failure(code: CLIErrorCode.invalidArgument, message: validationMessage)
    }
    guard let processID = context.callerProcessID,
      let caller = resolveCaller(processID)
    else {
      return failure(
        code: CLIErrorCode.sourceRequired,
        message: "Run 'prowl agents signal' from inside the Prowl pane that is reporting the event."
      )
    }

    let signal = AgentSignal(
      kind: kind(for: input),
      source: .cooperativeCLI,
      confidence: .exact,
      timestamp: now(),
      sessionID: input.sessionID,
      detail: input.detail,
      claimedOrigin: input.origin
    )
    let binding: AgentSignalBinding
    switch recordSignal(caller, signal) {
    case .recorded(let recordedBinding):
      // Receipts report the binding decided at attribution time, which is never `stale`;
      // collapse defensively so the wire contract stays `current` | `unbound`.
      binding = recordedBinding == .current ? .current : .unbound
    case .paneGone:
      return failure(
        code: CLIErrorCode.agentGone,
        message: "The caller pane closed before its agent signal could be recorded."
      )
    }

    let warnings: [AgentSignalWarning] =
      switch binding {
      case .current:
        []
      case .unbound, .stale:
        [
          AgentSignalWarning(
            code: .signalUnbound,
            message:
              "The signal was attributed to the pane but not to its current agent, so it is recorded "
              + "as diagnostics only and will not satisfy waits or dispatches. Run it from a process "
              + "descending from the pane's agent, or pass --session with the agent's current session id."
          )
        ]
      }
    let payload = AgentSignalCommandPayload(
      pane: AgentSignalPanePayload(
        id: caller.surfaceID.uuidString,
        worktreeID: caller.worktreeID
      ),
      signal: AgentSignalPayload(
        event: input.event,
        progress: input.progress,
        source: "cooperative_cli",
        confidence: signal.confidence.rawValue,
        binding: binding,
        timestamp: dateFormatter.string(from: signal.timestamp),
        sessionID: signal.sessionID,
        detail: signal.detail,
        claimedOrigin: signal.claimedOrigin
      ),
      warnings: warnings
    )
    do {
      return try CommandResponse(
        ok: true,
        command: "agents.signal",
        schemaVersion: "prowl.cli.agents.signal.v1",
        data: RawJSON(encoding: payload)
      )
    } catch {
      return failure(code: CLIErrorCode.agentsFailed, message: "Failed to encode the agent signal receipt.")
    }
  }
  // swiftlint:enable async_without_await

  private func kind(for input: AgentSignalInput) -> AgentSignal.Kind {
    switch input.event {
    case .turnEnded: .turnEnded
    case .needsInput: .needsInput
    case .sessionStart: .sessionStart
    case .sessionEnd: .sessionEnd
    case .progress: .progress(input.progress)
    }
  }

  private func failure(code: String, message: String) -> CommandResponse {
    CommandResponse(
      ok: false,
      command: "agents.signal",
      schemaVersion: "prowl.cli.agents.signal.v1",
      error: CommandError(code: code, message: message)
    )
  }
}
