import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct CLIAgentNativeHookCommandHandlerTests {
  @Test func exactCallerAndRegistrationProduceHookReceiptWithoutToken() async throws {
    let caller = CallerPane(worktreeID: "wt-1", surfaceID: UUID())
    var recorded: (CallerPane, AgentNativeHookInput)?
    let handler = AgentNativeHookCommandHandler(
      resolveCaller: { _ in caller },
      recordHook: { resolved, input in
        recorded = (resolved, input)
        return true
      },
      now: { Date(timeIntervalSince1970: 100) }
    )
    let input = makeInput()

    let response = await handler.handle(
      envelope: CommandEnvelope(output: .json, command: .agentsHook(input)),
      context: CLICommandContext(callerProcessID: 42)
    )

    #expect(response.ok)
    #expect(recorded?.0 == caller)
    #expect(recorded?.1 == input)
    let payload = try #require(try response.data?.decode(as: AgentSignalCommandPayload.self))
    #expect(payload.signal.source == "hook_claude")
    #expect(payload.signal.confidence == "exact")
    #expect(payload.signal.binding == .current)
    #expect(payload.warnings == nil)
    let encoded = try JSONEncoder().encode(response)
    let encodedText = try #require(String(bytes: encoded, encoding: .utf8))
    #expect(!encodedText.contains(input.token))
  }

  @Test func missingCallerAndRejectedRegistrationFailClosed() async {
    let input = makeInput()
    let missing = AgentNativeHookCommandHandler(resolveCaller: { _ in nil }, recordHook: { _, _ in true })
    let missingResponse = await missing.handle(
      envelope: CommandEnvelope(output: .json, command: .agentsHook(input)),
      context: CLICommandContext(callerProcessID: 42)
    )
    #expect(!missingResponse.ok)

    let caller = CallerPane(worktreeID: "wt-1", surfaceID: UUID())
    let rejected = AgentNativeHookCommandHandler(resolveCaller: { _ in caller }, recordHook: { _, _ in false })
    let rejectedResponse = await rejected.handle(
      envelope: CommandEnvelope(output: .json, command: .agentsHook(input)),
      context: CLICommandContext(callerProcessID: 42)
    )
    #expect(!rejectedResponse.ok)
  }

  private func makeInput() -> AgentNativeHookInput {
    AgentNativeHookInput(
      runtime: .claude,
      token: "private-token",
      signal: AgentNativeHookSignal(
        event: .sessionStart,
        nativeEvent: "SessionStart",
        cwd: "/tmp/project",
        sessionID: "session-1"
      )
    )
  }
}
