import Foundation
import Observation
import Testing

@testable import ProwlMirror_iOS

@MainActor
struct MirrorCommandTransportTests {
  @Test(.timeLimit(.minutes(1))) func hostWithoutShellCapabilityNeverReceivesShellInput() async {
    let channel = Channel()
    let session = makeSession(channel)
    session.connect()
    session.select(channel.pane)
    session.draft = "echo hello"
    channel.reply = { request in
      if case .list = request.request.command {
        let listing: MirrorJSON = .object([
          "ok": .bool(true),
          "data": .object(["items": .array([
            .object([
              "pane": .object(["id": .string(channel.pane.id.uuidString), "agent": .null]),
              "task": .object(["status": .string("idle")]),
            ])
          ])]),
        ])
        channel.onMessage?(.commandResult(.init(commandResponse: .init(
          requestID: request.requestID, response: listing))))
      } else {
        channel.respond(request.requestID, success: false)
      }
    }
    session.submitDraft()
    let changes = AsyncStream.makeStream(of: Void.self)
    defer { changes.continuation.finish() }
    changes.continuation.yield(())
    for await _ in changes.stream {
      let finished = withObservationTracking {
        session.submission?.outcome.status == .rejected
      } onChange: { changes.continuation.yield(()) }
      if finished { break }
    }
    #expect(channel.commands.count == 1)
    #expect(channel.commands.allSatisfy { $0.request.command.targetPaneID == nil })
    #expect(session.draft == "echo hello")
    #expect(session.canSubmit)
  }

  @Test func repliesAreCorrelatedAndCommandsAreNotReplayedAfterDisconnect() async throws {
    let channel = Channel()
    let session = makeSession(channel)
    session.connect()
    channel.reply = { request in
      channel.onMessage?(
        .commandResult(.init(commandResponse: .init(requestID: UUID(), response: .string("stale"))))
      )
      channel.onMessage?(
        .commandResult(
          .init(commandResponse: .init(requestID: request.requestID, response: .string("current"))))
      )
    }
    #expect(try await session.command(.list(.init())) == .string("current"))
    channel.reply = { _ in channel.onClose?("lost") }
    do {
      _ = try await session.command(.create(.init(worktreeID: "w", profileID: "p", prompt: nil)))
      Issue.record("A lost reply must be reported as unknown, not successful")
    } catch {}
    session.retry()
    #expect(channel.commands.count == 2)
  }

  @Test func hostsWithoutCommandSupportNeverReceiveLaunchRequests() async {
    let channel = Channel()
    channel.supportsLaunch = false
    let session = makeSession(channel)
    session.connect()
    do {
      _ = try await session.command(.profiles(.init()))
      Issue.record("Unsupported command must be refused locally")
    } catch {}
    #expect(channel.commands.isEmpty)
  }

  @Test func dispatchClearsOnlyTheSubmittedDraftAndRejectsWithoutLosingText() async {
    let channel = Channel()
    let session = makeSession(channel)
    session.connect()
    session.select(channel.pane)
    session.draft = "first\nsecond"
    #expect(session.canSubmit)
    session.submitDraft()
    let id = await channel.nextInput().requestID
    #expect(!session.canSubmit)
    session.draft = "new draft"
    channel.respond(id, success: true)
    #expect(session.draft == "new draft")
    #expect(session.submission?.outcome.status == .accepted)
    session.submitDraft()
    channel.respond(await channel.nextInput().requestID, success: false)
    #expect(session.draft == "new draft")
    #expect(session.submission?.outcome.status == .rejected)
  }

  @Test func disconnectedDispatchQueriesReceiptWithoutResendingText() async {
    let channel = Channel()
    let session = makeSession(channel)
    session.connect()
    session.select(channel.pane)
    session.draft = "hello"
    session.submitDraft()
    let request = await channel.nextInput()
    channel.onClose?("lost")
    #expect(session.submission?.outcome.status == .unknown)
    session.retry()
    #expect(channel.commands.count == 2)
    #expect(channel.receipts.last == request.requestID)
  }

  @Test(.timeLimit(.minutes(1))) func shellSendUsesFreshListingAndAcceptsPublicSendReceipt() async {
    let channel = Channel()
    channel.supportsShellSend = true
    let session = makeSession(channel)
    session.connect()
    session.select(channel.pane)
    session.draft = "echo hello"
    let request: MirrorCommandRequest = await withCheckedContinuation { continuation in
      channel.reply = { request in
        if case .list = request.request.command {
          let result: MirrorJSON = .object([
            "ok": .bool(true),
            "data": .object([
              "items": .array([
                .object([
                  "pane": .object(["id": .string(channel.pane.id.uuidString), "agent": .null]),
                  "task": .object(["status": .string("idle")]),
                ])
              ])
            ]),
          ])
          channel.onMessage?(
            .commandResult(
              .init(commandResponse: .init(requestID: request.requestID, response: result))))
        } else {
          continuation.resume(returning: request)
        }
      }
      session.submitDraft()
    }
    #expect(request.request.command == .send(.init(pane: channel.pane.id, text: "echo hello")))
    let result: MirrorJSON = .object([
      "ok": .bool(true), "command": .string("send"),
      "data": .object([
        "input": .object(["bytes": .number(10), "trailing_enter_sent": .bool(true)])
      ]),
    ])
    channel.onMessage?(
      .commandResult(.init(commandResponse: .init(requestID: request.requestID, response: result))))
    #expect(session.draft.isEmpty)
    #expect(session.submission?.outcome.status == .accepted)
  }

  private func makeSession(_ channel: Channel) -> MirrorSession {
    MirrorSession(
      configuration: .init(address: "127.0.0.1", port: 7880, pairingKey: "ABCD-EFGH"),
      makeTransport: { _ in channel })
  }

  private final class Channel: MirrorTransport {
    var onReady: (() -> Void)?
    var onMessage: ((MirrorMessage) -> Void)?
    var onClose: ((String?) -> Void)?
    var supportsLaunch = true
    var supportsShellSend = false
    var reply: ((MirrorCommandRequest) -> Void)?
    var commands: [MirrorCommandRequest] = []
    let inputs = AsyncStream.makeStream(of: MirrorCommandRequest.self)
    func nextInput() async -> MirrorCommandRequest {
      var iterator = inputs.stream.makeAsyncIterator()
      return await iterator.next()!
    }
    var receipts: [UUID] = []
    let pane = MirrorPaneDescriptor(id: UUID(), title: "Codex", directory: "/Project", busy: false)
    let run = UUID()
    func respond(_ id: UUID, success: Bool) {
      let json: MirrorJSON =
        success
        ? .object([
          "ok": .bool(true), "data": .object(["dispatch": .object(["id": .string("d1")])]),
        ])
        : .object([
          "ok": .bool(false),
          "error": .object(["code": .string("DISPATCH_TARGET_BUSY"), "message": .string("Busy")]),
        ])
      onMessage?(.commandResult(.init(commandResponse: .init(requestID: id, response: json))))
    }
    func start() { onReady?() }
    func close(_ reason: String?) { onClose?(reason) }
    func send(_ message: MirrorMessage, closeAfterSending: Bool) {
      if message.kind == .list {
        onMessage?(
          .panes(
            .init(
              panes: [pane],
              capabilities: ["text-v1", "agents-dispatch"]
                + (supportsLaunch ? ["launch-profile"] : [])
                + (supportsShellSend ? ["shell-send"] : []), hostRunID: UUID())))
      } else if message.kind == .subscribe {
        let lease = UUID()
        onMessage?(.subscribed(.init(paneID: pane.id, subscriptionID: lease, hostRunID: run)))
        onMessage?(.textFrame(.init(sequence: 1, text: "ready", subscriptionID: lease)))
      } else if let receipt = message.commandReceiptID {
        receipts.append(receipt)
      } else if let request = message.commandRequest {
        commands.append(request)
        if let reply {
          reply(request)
        } else if case .list = request.request.command {
          let listing: MirrorJSON = .object([
            "ok": .bool(true),
            "data": .object([
              "items": .array([
                .object([
                  "pane": .object(["id": .string(pane.id.uuidString), "agent": .string("codex")]),
                  "task": .object(["status": .string("idle")]),
                ])
              ])
            ]),
          ])
          onMessage?(
            .commandResult(
              .init(commandResponse: .init(requestID: request.requestID, response: listing))))
        }
        if request.request.command.targetPaneID != nil { inputs.continuation.yield(request) }
      }
    }
  }
}
