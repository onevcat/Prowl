import Foundation
import ProwlCLIShared

@MainActor
final class AgentNativeHookCommandHandler: CommandHandler {
  typealias ResolveCaller = @MainActor (CLICommandContext) -> CallerPane?
  typealias RecordHook = @MainActor (CallerPane, AgentNativeHookInput) -> Bool

  private let resolveCaller: ResolveCaller
  private let recordHook: RecordHook
  private let now: @Sendable () -> Date
  private let dateFormatter: ISO8601DateFormatter

  init(
    resolveCaller: @escaping ResolveCaller,
    recordHook: @escaping RecordHook,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.resolveCaller = resolveCaller
    self.recordHook = recordHook
    self.now = now
    dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
  }

  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    await handle(envelope: envelope, context: CLICommandContext())
  }

  // swiftlint:disable async_without_await
  func handle(
    envelope: CommandEnvelope,
    context: CLICommandContext
  ) async -> CommandResponse {
    guard case .agentsHook(let input) = envelope.command,
      input.validationErrorMessage == nil
    else {
      return failure(code: CLIErrorCode.invalidArgument)
    }
    guard context.callerProcessID != nil,
      let caller = resolveCaller(context),
      recordHook(caller, input)
    else {
      return failure(code: CLIErrorCode.sourceRequired)
    }
    let payload = AgentSignalCommandPayload(
      pane: AgentSignalPanePayload(
        id: caller.surfaceID.uuidString,
        worktreeID: caller.worktreeID
      ),
      signal: AgentSignalPayload(
        event: input.signal.event,
        progress: nil,
        source: "hook_\(input.runtime.rawValue)",
        confidence: AgentSignal.Confidence.exact.rawValue,
        binding: .current,
        timestamp: dateFormatter.string(from: now()),
        sessionID: input.signal.sessionID,
        detail: input.signal.detail,
        claimedOrigin: nil
      )
    )
    do {
      return try CommandResponse(
        ok: true,
        command: "agents.signal",
        schemaVersion: "prowl.cli.agents.signal.v1",
        data: RawJSON(encoding: payload)
      )
    } catch {
      return failure(code: CLIErrorCode.agentsFailed)
    }
  }
  // swiftlint:enable async_without_await

  private func failure(code: String) -> CommandResponse {
    CommandResponse(
      ok: false,
      command: "agents.signal",
      schemaVersion: "prowl.cli.agents.signal.v1",
      error: CommandError(code: code, message: "Managed agent hook signal rejected.")
    )
  }
}
