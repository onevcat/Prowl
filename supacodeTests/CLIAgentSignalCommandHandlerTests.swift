import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct CLIAgentSignalCommandHandlerTests {
  @Test func recordsSignalForExactCallerPaneAndReturnsReceipt() async throws {
    let pane = CallerPane(worktreeID: "/tmp/repo", surfaceID: UUID())
    var recorded: (CallerPane, AgentSignal)?
    let handler = AgentSignalCommandHandler(
      resolveCaller: { processID in
        #expect(processID == 42)
        return pane
      },
      recordSignal: { caller, signal in
        recorded = (caller, signal)
        return .recorded(binding: .current)
      },
      now: { Date(timeIntervalSince1970: 1_000) }
    )
    let input = AgentSignalInput(
      event: .turnEnded,
      origin: "manual-review",
      sessionID: "session-1",
      detail: "Review complete"
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(output: .json, command: .agentsSignal(input)),
      context: CLICommandContext(callerProcessID: 42)
    )

    #expect(response.ok)
    #expect(response.command == "agents.signal")
    #expect(response.schemaVersion == "prowl.cli.agents.signal.v1")
    let payload = try #require(try response.data?.decode(as: AgentSignalCommandPayload.self))
    #expect(payload.pane.id == pane.surfaceID.uuidString)
    #expect(payload.pane.worktreeID == pane.worktreeID)
    #expect(payload.signal.event == .turnEnded)
    #expect(payload.signal.progress == nil)
    #expect(payload.signal.source == "cooperative_cli")
    #expect(payload.signal.confidence == "exact")
    #expect(payload.signal.timestamp == "1970-01-01T00:16:40.000Z")
    #expect(payload.signal.sessionID == "session-1")
    #expect(payload.signal.detail == "Review complete")
    #expect(payload.signal.claimedOrigin == "manual-review")
    #expect(payload.signal.binding == .current)
    #expect(payload.warnings == nil)
    #expect(recorded?.0 == pane)
    #expect(recorded?.1.kind == .turnEnded)
    #expect(recorded?.1.source == .cooperativeCLI)
    #expect(recorded?.1.confidence == .exact)
    #expect(recorded?.1.timestamp == Date(timeIntervalSince1970: 1_000))
  }

  @Test func unboundSignalSucceedsWithBindingAndWarning() async throws {
    let pane = CallerPane(worktreeID: "wt", surfaceID: UUID())
    let handler = AgentSignalCommandHandler(
      resolveCaller: { _ in pane },
      recordSignal: { _, _ in .recorded(binding: .unbound) }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(output: .json, command: .agentsSignal(AgentSignalInput(event: .needsInput))),
      context: CLICommandContext(callerProcessID: 7)
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: AgentSignalCommandPayload.self))
    #expect(payload.signal.binding == .unbound)
    #expect(payload.signal.confidence == "exact")
    let warnings = try #require(payload.warnings)
    #expect(warnings.count == 1)
    #expect(warnings.first?.code == .signalUnbound)
    #expect(warnings.first?.message.isEmpty == false)
  }

  @Test func supportsIndeterminateAndBoundedProgress() async throws {
    var signals: [AgentSignal] = []
    let pane = CallerPane(worktreeID: "wt", surfaceID: UUID())
    let handler = AgentSignalCommandHandler(
      resolveCaller: { _ in pane },
      recordSignal: { _, signal in
        signals.append(signal)
        return .recorded(binding: .current)
      }
    )

    for value in [nil, 0, 100] as [Int?] {
      let response = await handler.handle(
        envelope: CommandEnvelope(
          output: .json,
          command: .agentsSignal(AgentSignalInput(event: .progress, progress: value))
        ),
        context: CLICommandContext(callerProcessID: 7)
      )
      #expect(response.ok)
    }

    #expect(signals.map(\.kind) == [.progress(nil), .progress(0), .progress(100)])
  }

  @Test func rejectsMissingCallerWithoutRecording() async {
    var didRecord = false
    let handler = AgentSignalCommandHandler(
      resolveCaller: { _ in nil },
      recordSignal: { _, _ in
        didRecord = true
        return .recorded(binding: .current)
      }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(output: .json, command: .agentsSignal(AgentSignalInput(event: .needsInput))),
      context: CLICommandContext(callerProcessID: nil)
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.sourceRequired)
    #expect(didRecord == false)
  }

  @Test func rejectsClosedCallerPane() async {
    let handler = AgentSignalCommandHandler(
      resolveCaller: { _ in CallerPane(worktreeID: "wt", surfaceID: UUID()) },
      recordSignal: { _, _ in .paneGone }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(output: .json, command: .agentsSignal(AgentSignalInput(event: .sessionEnd))),
      context: CLICommandContext(callerProcessID: 7)
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.agentGone)
  }

  @Test func validatesWireInputBeforeCallerResolution() async {
    var resolved = false
    let handler = AgentSignalCommandHandler(
      resolveCaller: { _ in
        resolved = true
        return nil
      },
      recordSignal: { _, _ in .recorded(binding: .current) }
    )
    let maximumDetail = AgentSignalInput(
      event: .needsInput,
      detail: String(repeating: "x", count: 32_768)
    )
    #expect(maximumDetail.validationErrorMessage == nil)

    let invalidInputs = [
      AgentSignalInput(event: .turnEnded, progress: 1),
      AgentSignalInput(event: .progress, progress: -1),
      AgentSignalInput(event: .progress, progress: 101),
      AgentSignalInput(event: .needsInput, sessionID: ""),
      AgentSignalInput(event: .needsInput, origin: "bad\norigin"),
      AgentSignalInput(event: .needsInput, detail: "bad\u{0}detail"),
      AgentSignalInput(event: .needsInput, detail: String(repeating: "x", count: 32_769)),
    ]

    for input in invalidInputs {
      let response = await handler.handle(
        envelope: CommandEnvelope(output: .json, command: .agentsSignal(input)),
        context: CLICommandContext(callerProcessID: 7)
      )
      #expect(response.ok == false)
      #expect(response.error?.code == CLIErrorCode.invalidArgument)
    }
    #expect(resolved == false)
  }
}
