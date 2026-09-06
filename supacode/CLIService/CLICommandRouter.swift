// supacode/CLIService/CLICommandRouter.swift
// Routes incoming command envelopes to the appropriate handler.

import Foundation
import ProwlCLIShared

@MainActor
final class CLICommandRouter {
  private let openHandler: any CommandHandler
  private let listHandler: any CommandHandler
  private let agentsHandler: any CommandHandler
  private let agentsReadHandler: any CommandHandler
  private let agentsSignalHandler: any CommandHandler
  private let agentsHookHandler: any CommandHandler
  private let agentsDispatchHandler: any CommandHandler
  private let agentsDispatchCompleteHandler: any CommandHandler
  private let agentsDispatchAbandonHandler: any CommandHandler
  private let agentsWaitHandler: any CommandHandler
  private let profilesHandler: any CommandHandler
  private let focusHandler: any CommandHandler
  private let sendHandler: any CommandHandler
  private let keyHandler: any CommandHandler
  private let readHandler: any CommandHandler
  private let createHandler: any CommandHandler
  private let closeHandler: any CommandHandler
  private let tabHandler: any CommandHandler
  private let paneHandler: any CommandHandler
  private let handoffHandler: any CommandHandler
  private let workflowHandler: any CommandHandler

  init(
    openHandler: any CommandHandler = StubCommandHandler(command: "open"),
    listHandler: any CommandHandler = StubCommandHandler(command: "list"),
    agentsHandler: any CommandHandler = StubCommandHandler(command: "agents"),
    agentsReadHandler: any CommandHandler = StubCommandHandler(command: "agents.read"),
    agentsSignalHandler: any CommandHandler = StubCommandHandler(command: "agents.signal"),
    agentsHookHandler: any CommandHandler = StubCommandHandler(command: "agents._hook"),
    agentsDispatchHandler: any CommandHandler = StubCommandHandler(command: "agents.dispatch"),
    agentsDispatchCompleteHandler: any CommandHandler = StubCommandHandler(command: "agents.dispatch-complete"),
    agentsDispatchAbandonHandler: any CommandHandler = StubCommandHandler(command: "agents.dispatch-abandon"),
    agentsWaitHandler: any CommandHandler = StubCommandHandler(command: "agents.wait"),
    profilesHandler: any CommandHandler = StubCommandHandler(command: "profiles"),
    focusHandler: any CommandHandler = StubCommandHandler(command: "focus"),
    sendHandler: any CommandHandler = StubCommandHandler(command: "send"),
    keyHandler: any CommandHandler = StubCommandHandler(command: "key"),
    readHandler: any CommandHandler = StubCommandHandler(command: "read"),
    createHandler: any CommandHandler = StubCommandHandler(command: "create"),
    closeHandler: any CommandHandler = StubCommandHandler(command: "close"),
    tabHandler: any CommandHandler = StubCommandHandler(command: "tab"),
    paneHandler: any CommandHandler = StubCommandHandler(command: "pane"),
    handoffHandler: any CommandHandler = StubCommandHandler(command: "handoff"),
    workflowHandler: any CommandHandler = StubCommandHandler(command: "workflow")
  ) {
    self.openHandler = openHandler
    self.listHandler = listHandler
    self.agentsHandler = agentsHandler
    self.agentsReadHandler = agentsReadHandler
    self.agentsSignalHandler = agentsSignalHandler
    self.agentsHookHandler = agentsHookHandler
    self.agentsDispatchHandler = agentsDispatchHandler
    self.agentsDispatchCompleteHandler = agentsDispatchCompleteHandler
    self.agentsDispatchAbandonHandler = agentsDispatchAbandonHandler
    self.agentsWaitHandler = agentsWaitHandler
    self.profilesHandler = profilesHandler
    self.focusHandler = focusHandler
    self.sendHandler = sendHandler
    self.keyHandler = keyHandler
    self.readHandler = readHandler
    self.createHandler = createHandler
    self.closeHandler = closeHandler
    self.tabHandler = tabHandler
    self.paneHandler = paneHandler
    self.handoffHandler = handoffHandler
    self.workflowHandler = workflowHandler
  }

  // Intentional exhaustive routing table for the public CLI command union.
  // swiftlint:disable:next cyclomatic_complexity
  func route(
    _ envelope: CommandEnvelope,
    context: CLICommandContext = CLICommandContext()
  ) async -> CommandResponse {
    let handler: any CommandHandler
    switch envelope.command {
    case .open: handler = openHandler
    case .list: handler = listHandler
    case .agents: handler = agentsHandler
    case .agentsRead: handler = agentsReadHandler
    case .agentsSignal: handler = agentsSignalHandler
    case .agentsHook: handler = agentsHookHandler
    case .agentsDispatch: handler = agentsDispatchHandler
    case .agentsDispatchComplete: handler = agentsDispatchCompleteHandler
    case .agentsDispatchAbandon: handler = agentsDispatchAbandonHandler
    case .agentsWait: handler = agentsWaitHandler
    case .profiles: handler = profilesHandler
    case .focus: handler = focusHandler
    case .send: handler = sendHandler
    case .key: handler = keyHandler
    case .read: handler = readHandler
    case .create: handler = createHandler
    case .close: handler = closeHandler
    case .tab: handler = tabHandler
    case .pane: handler = paneHandler
    case .handoff: handler = handoffHandler
    case .workflow: handler = workflowHandler
    }
    return await handler.handle(envelope: envelope, context: context)
  }
}

// MARK: - Stub handler (placeholder until real handlers are implemented)

struct StubCommandHandler: CommandHandler {
  let command: String

  // swiftlint:disable:next async_without_await
  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    CommandResponse(
      ok: false,
      command: command,
      schemaVersion: "prowl.cli.\(command).v1",
      error: CommandError(
        code: "NOT_IMPLEMENTED",
        message: "Command '\(command)' is not yet implemented."
      )
    )
  }
}
