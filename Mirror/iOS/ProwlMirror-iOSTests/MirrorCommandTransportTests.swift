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

  /// A draft on the Mac refuses the message with its text; Replace sends again with `on_draft`
  /// and the receipt names the stashed draft (docs-ai 090).
  @Test func draftRefusalOffersReplaceWhichResendsWithThePolicy() async {
    let channel = Channel(agent: "claude")
    let session = makeSession(channel)
    session.connect()
    session.select(channel.pane)
    session.draft = "hello"
    session.submitDraft()
    let first = await channel.nextInput()
    guard case .agentsInput(let firstInput) = first.request.command else { return Issue.record("expected agent input") }
    #expect(firstInput.onDraft == nil)
    channel.refuseForDraft(first.requestID)
    #expect(session.submission?.outcome.status == .rejected)
    #expect(session.hostDraft == .init(text: "review the tests", isComplete: true, replaceable: true, recovery: "stash"))
    #expect(session.draft == "hello")

    session.replaceHostDraftAndSend()
    let second = await channel.nextInput()
    guard case .agentsInput(let secondInput) = second.request.command else { return Issue.record("expected agent input") }
    #expect(secondInput.onDraft == "replace")
    #expect(secondInput.prompt == "hello")
    channel.respondReplaced(second.requestID)
    #expect(session.submission?.outcome.status == .accepted)
    #expect(session.submission?.outcome.replacedDraft?.recovery == "stash")
    #expect(session.submission?.outcome.detail.contains("stashed") == true)
    #expect(session.hostDraft == nil)
    #expect(session.draft.isEmpty)

    // The next message is an ordinary one again.
    session.draft = "next"
    session.submitDraft()
    guard case .agentsInput(let third) = await channel.nextInput().request.command else {
      return Issue.record("expected agent input")
    }
    #expect(third.onDraft == nil)
  }

  @Test func bringingTheDraftHereMergesTextAndMakesTheNextSendReplace() async {
    let channel = Channel(agent: "claude")
    let session = makeSession(channel)
    session.connect()
    session.select(channel.pane)
    session.draft = "hello"
    session.submitDraft()
    let first = await channel.nextInput()
    channel.refuseForDraft(first.requestID)
    session.bringHostDraftHere()
    #expect(session.draft == "review the tests\nhello")
    #expect(session.submission == nil && session.hostDraft == nil)
    session.submitDraft()
    guard case .agentsInput(let merged) = await channel.nextInput().request.command else {
      return Issue.record("expected agent input")
    }
    #expect(merged.onDraft == "replace")
    #expect(merged.prompt == "review the tests\nhello")

    // A draft the screen cannot carry (a paste marker) cannot be brought over, only replaced or left.
    let hidden = Channel(agent: "claude")
    let other = makeSession(hidden)
    other.connect()
    other.select(hidden.pane)
    other.draft = "hi"
    other.submitDraft()
    hidden.refuseForDraft(await hidden.nextInput().requestID, isComplete: false)
    other.bringHostDraftHere()
    #expect(other.draft == "hi" && other.hostDraft != nil)
    other.dismissHostDraft()
    #expect(other.hostDraft == nil && other.draft == "hi")
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

  @Test(.timeLimit(.minutes(1))) func oldHostRejectsWithoutDispatchFallback() async {
    let channel = Channel()
    channel.supportsAgentInput = false
    let session = makeSession(channel)
    session.connect()
    session.select(channel.pane)
    session.draft = "hello"
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
    #expect(session.draft == "hello")
    #expect(session.submission?.outcome.detail.contains("Update Host") == true)
  }

  /// While the Host delivers a message, a prompt answer waits instead of sending a second
  /// command, which the Host would answer by closing the connection (089 review S5-R4).
  @Test(.timeLimit(.minutes(1))) func promptAnswersWaitWhileAMessageIsBeingDelivered() async {
    let channel = Channel(agent: "codex")
    let session = makeSession(channel)
    session.connect()
    session.select(channel.pane)
    session.draft = "hello"
    session.submitDraft()
    let input = await channel.nextInput()
    #expect(session.isDeliveringMessage)
    session.answerPrompt("screen:a.1", choice: "1")
    for _ in 0..<20 { await Task.yield() }
    #expect(channel.commands.count == 2)
    guard case .refused = session.promptAnswer?.state else {
      Issue.record("expected the answer to wait")
      return
    }
    channel.respond(input.requestID, success: true)
    #expect(!session.isDeliveringMessage)
    session.answerPrompt("screen:a.1", choice: "1")
    guard case .promptRespond = await channel.nextInput().request.command else {
      Issue.record("expected the answer after delivery")
      return
    }
  }

  /// Keys wait for a message the Host is still delivering, like prompt answers (089 review
  /// S5-R4): the key bar is disabled and nothing else goes to the Host.
  @Test(.timeLimit(.minutes(1))) func keysWaitWhileAMessageIsBeingDelivered() async {
    let channel = Channel(agent: "codex")
    let session = makeSession(channel)
    session.connect()
    session.select(channel.pane)
    #expect(session.canSendKeys)
    session.draft = "hello"
    session.submitDraft()
    let input = await channel.nextInput()
    #expect(session.keysAvailable && !session.canSendKeys)
    session.sendKeys(["esc"])
    for _ in 0..<20 { await Task.yield() }
    #expect(channel.commands.count == 2)
    channel.respond(input.requestID, success: true)
    #expect(session.canSendKeys)
    session.sendKeys(["esc"])
    guard case .agentKeys = await channel.nextInput().request.command else {
      Issue.record("expected the key after delivery")
      return
    }
  }

  /// A delivery that timed out may still hold the Host's command, so answers keep waiting
  /// until a receipt or "I've Checked" (089 review S5-R4, round 4).
  @Test(.timeLimit(.minutes(1))) func promptAnswersWaitWhileADeliveryIsUnknown() async {
    let clock = HostTestClock()
    let channel = Channel(agent: "codex")
    let session = makeSession(channel, clock: clock)
    session.connect()
    session.select(channel.pane)
    session.draft = "hello"
    session.submitDraft()
    _ = await channel.nextInput()
    while session.submission?.outcome.status != .unknown {
      _ = await clock.nextSleep()
      await clock.advance()
      await Task.yield()
    }
    #expect(session.isDeliveringMessage)
    session.answerPrompt("screen:a.1", choice: "1")
    #expect(!session.canSendKeys)
    session.sendKeys(["esc"])
    for _ in 0..<20 { await Task.yield() }
    #expect(channel.commands.count == 2)
    session.acknowledgeUnknownSubmission()
    #expect(!session.isDeliveringMessage)
  }

  /// Terminal view: the text subscription asks for screen prompts and keeps the latest one of
  /// its own lease (089 S4 follow-up).
  @Test(.timeLimit(.minutes(1))) func terminalSubscriptionTracksTheScreenPrompt() async throws {
    let channel = Channel(agent: "claude")
    let session = makeSession(channel)
    session.connect()
    session.select(channel.pane)
    #expect(channel.subscribes.last?.representation == .text)
    #expect(channel.subscribes.last?.includeScreenPrompt == true)
    let lease = try #require(channel.lease)
    let prompt = MirrorConversationEvent.Prompt(
      id: "screen:a.1", kind: .question, title: "Ready to submit your answers?",
      choices: [.init(id: "1", label: "Submit answers"), .init(id: "2", label: "Cancel")], freeform: false)
    channel.onMessage?(.screenPrompt(.init(prompt: prompt, subscriptionID: UUID())))
    #expect(session.screenPrompt == nil)
    channel.onMessage?(.screenPrompt(.init(prompt: prompt, subscriptionID: lease)))
    #expect(session.screenPrompt?.id == "screen:a.1")
    channel.onMessage?(.screenPrompt(.init(prompt: nil, subscriptionID: lease)))
    #expect(session.screenPrompt == nil)
  }

  /// Multi-select: boxes may change one after another; after Submit nothing more goes.
  @Test(.timeLimit(.minutes(1))) func multiSelectBoxesToggleUntilSubmitted() async {
    let channel = Channel(agent: "claude")
    let session = makeSession(channel)
    session.connect()
    session.select(channel.pane)
    func answer(_ choice: String, toggles: Bool) async -> MirrorCommandRequest.PromptRespond? {
      let count = channel.commands.count
      session.answerPrompt("screen:m.1", choice: choice, toggles: toggles)
      for _ in 0..<200 { await Task.yield() }
      guard let request = channel.commands.dropFirst(count).first,
        case .promptRespond(let sent) = request.request.command
      else {
        Issue.record("no answer for \(choice): \(String(describing: session.promptAnswer))")
        return nil
      }
      channel.respond(request.requestID, success: true)
      for _ in 0..<200 { await Task.yield() }
      if session.promptAnswer?.state != .delivered {
        Issue.record("answer \(choice) not delivered: \(String(describing: session.promptAnswer))")
      }
      return sent
    }
    #expect(await answer("1", toggles: true)?.choice == "1")
    #expect(await answer("2", toggles: true)?.choice == "2")
    #expect(await answer(MirrorSession.submitChoice, toggles: false)?.choice == "submit")
    let count = channel.commands.count
    session.answerPrompt("screen:m.1", choice: "3", toggles: true)
    for _ in 0..<20 { await Task.yield() }
    #expect(channel.commands.count == count)
  }

  /// Shell panes get the key bar (⌃C, Tab, arrows) only from a Host that presses keys there.
  @Test(.timeLimit(.minutes(1))) func shellPanesGetKeysFromAHostThatSupportsThem() {
    let old = Channel()
    let oldSession = makeSession(old)
    oldSession.connect()
    oldSession.select(old.pane)
    #expect(!oldSession.keysAvailable)
    let channel = Channel()
    channel.supportsShellKeys = true
    let session = makeSession(channel)
    session.connect()
    session.select(channel.pane)
    #expect(session.keysAvailable)
  }

  private func makeSession(_ channel: Channel, clock: any Clock<Duration> = ContinuousClock()) -> MirrorSession {
    MirrorSession(
      configuration: .init(address: "127.0.0.1", port: 7880, pairingKey: "ABCD-EFGH"), clock: clock,
      makeTransport: { _ in channel })
  }

  private final class Channel: MirrorTransport {
    var onReady: (() -> Void)?
    var onMessage: ((MirrorMessage) -> Void)?
    var onClose: ((String?) -> Void)?
    var supportsLaunch = true
    var supportsShellSend = false
    var supportsShellKeys = false
    var supportsAgentInput = true
    var reply: ((MirrorCommandRequest) -> Void)?
    var commands: [MirrorCommandRequest] = []
    let inputs = AsyncStream.makeStream(of: MirrorCommandRequest.self)
    func nextInput() async -> MirrorCommandRequest {
      var iterator = inputs.stream.makeAsyncIterator()
      return await iterator.next()!
    }
    var receipts: [UUID] = []
    var subscribes: [MirrorMessage.SubscribePayload] = []
    var lease: UUID?
    let pane: MirrorPaneDescriptor
    /// An agent pane on a Host that answers prompts and presses keys.
    let agent: String?
    init(agent: String? = nil) {
      self.agent = agent
      pane = MirrorPaneDescriptor(id: UUID(), title: "Codex", directory: "/Project", busy: false, agent: agent)
    }
    let run = UUID()
    func respond(_ id: UUID, success: Bool) {
      let json: MirrorJSON =
        success
        ? .object([
          "ok": .bool(true), "command": .string("agents.input"),
          "data": .object(["input": .object([
            "bytes": .number(Double(commands.first(where: { $0.requestID == id }).map {
              if case .agentsInput(let input) = $0.request.command { return input.prompt.utf8.count }
              return 0
            } ?? 0)), "trailing_enter_sent": .bool(true),
          ])]),
        ])
        : .object([
          "ok": .bool(false),
          "error": .object(["code": .string("DISPATCH_TARGET_BUSY"), "message": .string("Busy")]),
        ])
      onMessage?(.commandResult(.init(commandResponse: .init(requestID: id, response: json))))
    }
    /// The Mac's input box holds a draft (docs-ai 090).
    func refuseForDraft(_ id: UUID, replaceable: Bool = true, isComplete: Bool = true) {
      onMessage?(
        .commandResult(
          .init(
            commandResponse: .init(
              requestID: id,
              response: .object([
                "ok": .bool(false),
                "error": .object([
                  "code": .string("DISPATCH_TARGET_BUSY"),
                  "message": .string("Claude has an existing draft or attachment (“review the tests”)."),
                  "details": .object([
                    "input": .object([
                      "reason": .string("draft"),
                      "draft": .object(["text": .string("review the tests"), "is_complete": .bool(isComplete)]),
                      "replaceable": .bool(replaceable), "recovery": .string("stash"),
                    ])
                  ]),
                ]),
              ])))))
    }
    /// Delivered after the Host stashed the Mac's draft.
    func respondReplaced(_ id: UUID) {
      let bytes = commands.first(where: { $0.requestID == id }).map {
        if case .agentsInput(let input) = $0.request.command { return input.prompt.utf8.count }
        return 0
      } ?? 0
      onMessage?(
        .commandResult(
          .init(
            commandResponse: .init(
              requestID: id,
              response: .object([
                "ok": .bool(true), "command": .string("agents.input"),
                "data": .object([
                  "input": .object([
                    "bytes": .number(Double(bytes)), "trailing_enter_sent": .bool(true),
                    "replaced_draft": .object([
                      "text": .string("review the tests"), "is_complete": .bool(true), "recovery": .string("stash"),
                    ]),
                  ])
                ]),
              ])))))
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
                + (supportsAgentInput ? ["agent-input"] : [])
                + (supportsLaunch ? ["launch-profile"] : [])
                + (supportsShellSend ? ["shell-send"] : [])
                + (supportsShellKeys ? ["agent-keys", "shell-keys"] : [])
                + (agent != nil ? ["prompt-respond", "agent-keys"] : []), hostRunID: UUID())))
      } else if message.kind == .subscribe {
        let lease = UUID()
        self.lease = lease
        if case .subscribe(let payload) = message { subscribes.append(payload) }
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
