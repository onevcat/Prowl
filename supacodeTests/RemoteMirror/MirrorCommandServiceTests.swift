import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct MirrorCommandServiceTests {
  @Test func concurrentDuplicateCreationUsesOneRouterInvocation() async throws {
    let handler = Handler()
    let service = MirrorCommandService(router: CLICommandRouter(createHandler: handler))
    let request = creation(id: UUID(), prompt: "first\nsecond")
    let first = Task { await service.execute(request) }
    let second = Task { await service.execute(request) }
    let responses = await (first.value, second.value)
    #expect(handler.count == 1)
    #expect(responses.0.response == responses.1.response)
    #expect(handler.receivedPrompt == "first\nsecond")
  }

  @Test func requestIDCannotBeReusedToCreateAnotherPane() async throws {
    let handler = Handler()
    let service = MirrorCommandService(router: CLICommandRouter(createHandler: handler))
    let id = UUID()
    _ = await service.execute(creation(id: id, prompt: "first"))
    let result = await service.execute(creation(id: id, prompt: "different"))
    #expect(try result.response.decode(CommandResponse.self).ok == false)
    #expect(handler.count == 1)
  }

  @Test func cacheLimitRefusesNewMutationsWithoutEvictingReceipts() async throws {
    let handler = Handler()
    let service = MirrorCommandService(
      router: CLICommandRouter(createHandler: handler), maximumRequests: 1)
    let original = creation(id: UUID(), prompt: nil)
    _ = await service.execute(original)
    let rejected = await service.execute(creation(id: UUID(), prompt: nil))
    #expect(try rejected.response.decode(CommandResponse.self).ok == false)
    _ = await service.execute(original)
    #expect(handler.count == 1)
  }

  @Test func catalogReadsDoNotConsumeMutationReceipts() async throws {
    let mutations = Handler()
    let catalog = ShellHandlers(agent: nil, state: .idle)
    let service = MirrorCommandService(
      router: CLICommandRouter(listHandler: catalog, createHandler: mutations), maximumRequests: 1)
    for _ in 0..<3 {
      let read = MirrorCommandRequest(requestID: UUID(), request: .init(command: .list(.init())))
      #expect(try await service.execute(read).response.decode(CommandResponse.self).ok)
    }
    let mutation = creation(id: UUID(), prompt: nil)
    #expect(try await service.execute(mutation).response.decode(CommandResponse.self).ok)
    let read = MirrorCommandRequest(requestID: UUID(), request: .init(command: .list(.init())))
    #expect(try await service.execute(read).response.decode(CommandResponse.self).ok)
    #expect(try await service.execute(mutation).response.decode(CommandResponse.self).ok)
    #expect(mutations.count == 1)
    let collision = MirrorCommandRequest(requestID: mutation.requestID, request: read.request)
    #expect(try await service.execute(collision).response.decode(CommandResponse.self).ok == false)
  }

  @Test func unsupportedCommandsCannotDecodeThroughTheAllowlist() {
    let payload = Data(
      #"""
      {"requestID":"03F5535A-D08C-498C-B70B-C665AC8D02CB",
       "request":{"output":"json","command":{"send":{"_0":{"text":"unsafe"}}}}}
      """#.utf8)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(MirrorCommandRequest.self, from: payload)
    }
  }

  @Test func dispatchUsesPublicEnvelopeAndReceiptDoesNotReplay() async throws {
    let handler = DispatchHandler()
    let service = MirrorCommandService(router: CLICommandRouter(agentsDispatchHandler: handler))
    let pane = UUID()
    let request = MirrorCommandRequest(
      requestID: UUID(),
      request: .init(
        command: .agentsDispatch(.init(pane: pane.uuidString, prompt: "first\nsecond"))))
    let first = await service.execute(request)
    let receipt = await service.receipt(request.requestID, paneID: pane)
    #expect(first.response == receipt.response)
    #expect(handler.count == 1)
    #expect(handler.prompt == "first\nsecond")
    let otherPane = await service.receipt(request.requestID, paneID: UUID())
    #expect(try otherPane.response.decode(CommandResponse.self).ok == false)
  }

  @Test func revokedLeaseCannotRouteDispatch() async throws {
    let handler = DispatchHandler()
    let service = MirrorCommandService(router: CLICommandRouter(agentsDispatchHandler: handler))
    let request = MirrorCommandRequest(
      requestID: UUID(),
      request: .init(
        command: .agentsDispatch(.init(pane: UUID().uuidString, prompt: "hello"))))
    let result = await service.execute(request, authorize: { false })
    #expect(try result.response.decode(CommandResponse.self).ok == false)
    #expect(handler.count == 0)
  }

  private final class DispatchHandler: CommandHandler {
    var count = 0
    var prompt: String?
    func handle(envelope: CommandEnvelope) async -> CommandResponse {
      count += 1
      await Task.yield()
      if case .agentsDispatch(let input) = envelope.command { prompt = input.prompt }
      return CommandResponse(
        ok: true, command: "agents.dispatch", schemaVersion: "prowl.cli.agents.dispatch.v1")
    }
  }

  @Test func shellSendRefusesUnverifiedInputRegardlessOfTaskState() async throws {
    for (agent, state) in [
      (String?.none, ListCommandTask.Status?.some(.idle)),
      ("claude", .some(.idle)), (nil, .some(.running)), (nil, nil),
    ] {
      let handler = ShellHandlers(agent: agent, state: state)
      let service = MirrorCommandService(
        router: CLICommandRouter(listHandler: handler, sendHandler: handler))
      let request = MirrorCommandRequest(
        requestID: UUID(),
        request: .init(
          command: .send(
            .init(
              pane: handler.paneID, text: "echo hello"))))
      let result = await service.execute(request)
      #expect(try result.response.decode(CommandResponse.self).ok == false)
      #expect(handler.sends == 0)
      _ = await service.receipt(request.requestID, paneID: handler.paneID)
      #expect(handler.sends == 0)
    }
  }

  @Test func remoteShellSendCannotAppendToAnUnverifiedHostDraft() async throws {
    let handler = ShellHandlers(agent: nil, state: .idle)
    let service = MirrorCommandService(
      router: CLICommandRouter(listHandler: handler, sendHandler: handler))
    let request = MirrorCommandRequest(
      requestID: UUID(),
      request: .init(
        command: .send(
          .init(
            pane: handler.paneID, text: "echo REMOTE"))))
    let result = try await service.execute(request).response.decode(CommandResponse.self)
    #expect(!result.ok)
    #expect(result.error?.code == "REMOTE_COMMAND_REJECTED")
    #expect(handler.sends == 0)
    #expect(handler.reads == 0)
    #expect(try await service.execute(request).response.decode(CommandResponse.self).ok == false)
    #expect(handler.sends == 0)
  }

  private final class ShellHandlers: CommandHandler {
    let paneID = UUID()
    let agent: String?
    let state: ListCommandTask.Status?
    var sends = 0
    var reads = 0
    init(agent: String?, state: ListCommandTask.Status?) {
      self.agent = agent
      self.state = state
    }
    func handle(envelope: CommandEnvelope) async -> CommandResponse {
      await Task.yield()
      if case .send(let input) = envelope.command {
        sends += 1
        #expect(input.selector == .pane(paneID.uuidString))
        #expect(input.trailingEnter && !input.wait && !input.captureOutput)
        return CommandResponse(ok: true, command: "send", schemaVersion: "test")
      }
      reads += 1
      let item = ListCommandItem(
        worktree: .init(id: "w", name: "main", path: "/Project", rootPath: "/Project", kind: .git),
        tab: .init(id: "t", title: "Terminal", selected: true),
        pane: .init(
          id: paneID.uuidString, title: "Terminal", cwd: "/Project", focused: true, agent: agent),
        task: .init(status: state))
      do {
        return CommandResponse(
          ok: true, command: "list", schemaVersion: "test",
          data: try RawJSON(encoding: ListCommandPayload(count: 1, items: [item])))
      } catch {
        Issue.record(error)
        return CommandResponse(ok: false, command: "list", schemaVersion: "test")
      }
    }
  }

  private func creation(id: UUID, prompt: String?) -> MirrorCommandRequest {
    .init(
      requestID: id,
      request: .init(
        command: .create(
          .init(
            worktreeID: "worktree-1", profileID: "profile-1", prompt: prompt))))
  }

  private final class Handler: CommandHandler {
    var count = 0
    var receivedPrompt: String?
    func handle(envelope: CommandEnvelope) async -> CommandResponse {
      count += 1
      await Task.yield()
      if case .create(let create) = envelope.command {
        #expect(create.resource == .tab && create.background)
        #expect(create.selector == .worktree("worktree-1"))
        #expect(create.launch?.profile == "profile-1")
        receivedPrompt = create.launch?.prompt
      } else {
        Issue.record("Unexpected command")
      }
      return CommandResponse(ok: true, command: "create", schemaVersion: "prowl.cli.create.v1")
    }
  }
}
