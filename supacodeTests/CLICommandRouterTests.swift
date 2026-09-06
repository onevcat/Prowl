// supacodeTests/CLICommandRouterTests.swift
// Unit tests for CLICommandRouter and StubCommandHandler.

import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct CLICommandRouterTests {

  // MARK: - Stub handler returns NOT_IMPLEMENTED

  @MainActor
  @Test func stubHandlerReturnsNotImplemented() async {
    let router = CLICommandRouter()
    let envelope = CommandEnvelope(output: .json, command: .list(ListInput()))
    let response = await router.route(envelope)
    #expect(response.ok == false)
    #expect(response.error?.code == "NOT_IMPLEMENTED")
    #expect(response.command == "list")
  }

  @MainActor
  @Test func routerDispatchesOpenToOpenHandler() async {
    let router = CLICommandRouter()
    let envelope = CommandEnvelope(
      output: .text,
      command: .open(OpenInput(path: "/tmp/test"))
    )
    let response = await router.route(envelope)
    #expect(response.command == "open")
    #expect(response.error?.code == "NOT_IMPLEMENTED")
  }

  @MainActor
  @Test func routerDispatchesSendToSendHandler() async {
    let router = CLICommandRouter()
    let envelope = CommandEnvelope(
      output: .json,
      command: .send(SendInput(text: "hello"))
    )
    let response = await router.route(envelope)
    #expect(response.command == "send")
    #expect(response.error?.code == "NOT_IMPLEMENTED")
  }

  @MainActor
  @Test func routerDispatchesFocusToFocusHandler() async {
    let router = CLICommandRouter()
    let envelope = CommandEnvelope(
      output: .text,
      command: .focus(FocusInput(selector: .pane("p1")))
    )
    let response = await router.route(envelope)
    #expect(response.command == "focus")
  }

  @MainActor
  @Test func routerDispatchesAgentsToAgentsHandler() async {
    let router = CLICommandRouter()
    let envelope = CommandEnvelope(
      output: .json,
      command: .agents(AgentsInput())
    )
    let response = await router.route(envelope)
    #expect(response.command == "agents")
    #expect(response.error?.code == "NOT_IMPLEMENTED")
  }

  @MainActor
  @Test func routerDispatchesAgentsSignalWithCallerContext() async {
    let handler = ContextRecordingCommandHandler(command: "agents.signal")
    let router = CLICommandRouter(agentsSignalHandler: handler)
    let envelope = CommandEnvelope(
      output: .json,
      command: .agentsSignal(AgentSignalInput(event: .turnEnded))
    )

    let response = await router.route(
      envelope,
      context: CLICommandContext(callerProcessID: 42)
    )

    #expect(response.command == "agents.signal")
    #expect(handler.callerProcessID == 42)
  }

  @MainActor
  @Test func routerDispatchesProfilesToProfilesHandler() async {
    let router = CLICommandRouter()
    let envelope = CommandEnvelope(
      output: .json,
      command: .profiles(ProfilesInput())
    )
    let response = await router.route(envelope)
    #expect(response.command == "profiles")
    #expect(response.error?.code == "NOT_IMPLEMENTED")
  }

  @MainActor
  @Test func routerDispatchesAgentsReadToAgentsReadHandler() async {
    let router = CLICommandRouter()
    let envelope = CommandEnvelope(
      output: .json,
      command: .agentsRead(AgentReadInput(pane: "p7"))
    )
    let response = await router.route(envelope)
    #expect(response.command == "agents.read")
    #expect(response.error?.code == "NOT_IMPLEMENTED")
  }

  @MainActor
  @Test func routerDispatchesKeyToKeyHandler() async {
    let router = CLICommandRouter()
    let envelope = CommandEnvelope(
      output: .json,
      command: .key(KeyInput(rawToken: "enter", token: "enter", repeatCount: 3))
    )
    let response = await router.route(envelope)
    #expect(response.command == "key")
  }

  @MainActor
  @Test func routerDispatchesReadToReadHandler() async {
    let router = CLICommandRouter()
    let envelope = CommandEnvelope(
      output: .text,
      command: .read(ReadInput(last: 10))
    )
    let response = await router.route(envelope)
    #expect(response.command == "read")
  }

  @MainActor
  @Test func routerDispatchesTabToTabHandler() async {
    let router = CLICommandRouter()
    let envelope = CommandEnvelope(
      output: .json,
      command: .tab(TabInput(action: .create))
    )
    let response = await router.route(envelope)
    #expect(response.command == "tab")
  }

  @MainActor
  @Test func routerDispatchesPaneToPaneHandler() async {
    let router = CLICommandRouter()
    let envelope = CommandEnvelope(
      output: .json,
      command: .pane(PaneInput(action: .close))
    )
    let response = await router.route(envelope)
    #expect(response.command == "pane")
  }

  // MARK: - Custom handler injection

  @MainActor
  @Test func routerUsesInjectedHandler() async {
    let customHandler = MockCommandHandler(
      response: CommandResponse(
        ok: true,
        command: "list",
        schemaVersion: "prowl.cli.list.v1"
      )
    )
    let router = CLICommandRouter(listHandler: customHandler)
    let envelope = CommandEnvelope(output: .json, command: .list(ListInput()))
    let response = await router.route(envelope)
    #expect(response.ok == true)
    #expect(response.command == "list")
  }

  // MARK: - Schema version format

  @MainActor
  @Test func stubSchemaVersionFollowsConvention() async {
    let commands: [Command] = [
      .open(OpenInput()),
      .list(ListInput()),
      .agents(AgentsInput()),
      .agentsRead(AgentReadInput(pane: "p7")),
      .agentsSignal(AgentSignalInput(event: .turnEnded)),
      .profiles(ProfilesInput()),
      .focus(FocusInput()),
      .send(SendInput(text: "x")),
      .key(KeyInput(rawToken: "tab", token: "tab")),
      .read(ReadInput()),
      .tab(TabInput(action: .create)),
      .pane(PaneInput(action: .close)),
    ]
    let router = CLICommandRouter()
    for cmd in commands {
      let envelope = CommandEnvelope(output: .json, command: cmd)
      let response = await router.route(envelope)
      #expect(response.schemaVersion.hasPrefix("prowl.cli."))
      #expect(response.schemaVersion.hasSuffix(".v1"))
    }
  }
}

// MARK: - Test helpers

private struct MockCommandHandler: CommandHandler {
  let response: CommandResponse

  // swiftlint:disable:next async_without_await
  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    response
  }
}

@MainActor
private final class ContextRecordingCommandHandler: CommandHandler {
  let command: String
  var callerProcessID: pid_t?

  init(command: String) {
    self.command = command
  }

  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    await handle(envelope: envelope, context: CLICommandContext())
  }

  // swiftlint:disable:next async_without_await
  func handle(envelope: CommandEnvelope, context: CLICommandContext) async -> CommandResponse {
    callerProcessID = context.callerProcessID
    return CommandResponse(
      ok: true,
      command: command,
      schemaVersion: "prowl.cli.\(command).v1"
    )
  }
}
