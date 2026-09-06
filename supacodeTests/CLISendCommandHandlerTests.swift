import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct CLISendCommandHandlerTests {

  // MARK: - Helpers

  private static let testPaneID = UUID(uuidString: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764")!
  private static let testTabID = UUID(uuidString: "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0")!

  private static func makeTarget() -> SendResolvedTarget {
    SendResolvedTarget(
      worktreeID: "Prowl:/Users/onevcat/Projects/Prowl",
      worktreeName: "Prowl",
      worktreePath: "/Users/onevcat/Projects/Prowl",
      worktreeRootPath: "/Users/onevcat/Projects/Prowl",
      worktreeKind: .git,
      tabID: testTabID,
      tabTitle: "Prowl 1",
      tabSelected: true,
      paneID: testPaneID,
      paneTitle: "zsh",
      paneCWD: "/Users/onevcat/Projects/Prowl",
      paneFocused: true
    )
  }

  private static func makeHandler(
    resolveResult: Result<SendResolvedTarget, TargetResolverError> = .success(makeTarget()),
    waiterResult: (exitCode: Int?, durationMs: Int)? = nil,
    waiterDelay: Duration? = nil,
    textDelivery: (@MainActor (SendResolvedTarget, String, Bool) -> Void)? = nil,
    captureProvider: (@MainActor (SendResolvedTarget) -> ReadCaptureInput?)? = nil
  ) -> SendCommandHandler {
    SendCommandHandler(
      resolveProvider: { _ in resolveResult },
      textDelivery: textDelivery ?? { _, _, _ in },
      waiterProvider: { _, _ in
        guard let waiterResult else { return nil }
        return AsyncStream { continuation in
          if let delay = waiterDelay {
            Task {
              try? await Task.sleep(for: delay)
              continuation.yield(waiterResult)
              continuation.finish()
            }
          } else {
            continuation.yield(waiterResult)
            continuation.finish()
          }
        }
      },
      captureProvider: captureProvider
    )
  }

  private static func makeEnvelope(
    text: String = "echo hello",
    trailingEnter: Bool = true,
    source: InputSource = .argv,
    wait: Bool = true,
    timeoutSeconds: Int? = nil,
    captureOutput: Bool = false
  ) -> CommandEnvelope {
    CommandEnvelope(
      output: .json,
      command: .send(
        SendInput(
          selector: .none,
          text: text,
          trailingEnter: trailingEnter,
          source: source,
          wait: wait,
          timeoutSeconds: timeoutSeconds,
          captureOutput: captureOutput
        ))
    )
  }

  // MARK: - Tests

  @Test func successfulSendWithWait() async throws {
    let handler = Self.makeHandler(
      waiterResult: (exitCode: 0, durationMs: 1234)
    )
    let response = await handler.handle(envelope: Self.makeEnvelope())

    #expect(response.ok)
    #expect(response.command == "send")
    #expect(response.schemaVersion == "prowl.cli.send.v1")

    let payload = try #require(try response.data?.decode(as: SendCommandPayload.self))
    #expect(payload.target.worktree.id == "Prowl:/Users/onevcat/Projects/Prowl")
    #expect(payload.target.worktree.kind == "git")
    #expect(payload.target.tab.id == Self.testTabID.uuidString)
    #expect(payload.target.tab.selected == true)
    #expect(payload.target.pane.id == Self.testPaneID.uuidString)
    #expect(payload.target.pane.focused == true)
    #expect(payload.input.source == "argv")
    #expect(payload.input.characters == 10)
    #expect(payload.input.bytes == 10)
    #expect(payload.input.trailingEnterSent == true)
    #expect(payload.createdTab == false)
    #expect(payload.wait?.exitCode == 0)
    #expect(payload.wait?.durationMs == 1234)
  }

  @Test func noWaitReturnsNullWait() async throws {
    let handler = Self.makeHandler()
    let response = await handler.handle(envelope: Self.makeEnvelope(wait: false))

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: SendCommandPayload.self))
    #expect(payload.wait == nil)
  }

  @Test func timeoutReturnsWaitTimeoutError() async throws {
    let handler = Self.makeHandler(
      waiterResult: (exitCode: 0, durationMs: 5000),
      waiterDelay: .seconds(10)
    )
    let response = await handler.handle(
      envelope: Self.makeEnvelope(timeoutSeconds: 1)
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.waitTimeout)
  }

  @Test func sourceFieldReflectsStdin() async throws {
    let handler = Self.makeHandler(
      waiterResult: (exitCode: 0, durationMs: 100)
    )
    let response = await handler.handle(
      envelope: Self.makeEnvelope(source: .stdin)
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: SendCommandPayload.self))
    #expect(payload.input.source == "stdin")
  }

  @Test func multibyteCounts() async throws {
    let handler = Self.makeHandler(
      waiterResult: (exitCode: 0, durationMs: 50)
    )
    // "café" = 4 unicode scalars, 5 UTF-8 bytes (é = 2 bytes)
    let response = await handler.handle(
      envelope: Self.makeEnvelope(text: "café")
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: SendCommandPayload.self))
    #expect(payload.input.characters == 4)
    #expect(payload.input.bytes == 5)
  }

  @Test func emojiCounts() async throws {
    let handler = Self.makeHandler(
      waiterResult: (exitCode: 0, durationMs: 50)
    )
    // "hi👋" = 3 unicode scalars (hi + wave), 6 UTF-8 bytes (h=1, i=1, 👋=4)
    let response = await handler.handle(
      envelope: Self.makeEnvelope(text: "hi👋")
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: SendCommandPayload.self))
    #expect(payload.input.characters == 3)
    #expect(payload.input.bytes == 6)
  }

  @Test func trailingEnterSentMatchesInput() async throws {
    let handler = Self.makeHandler(
      waiterResult: (exitCode: 0, durationMs: 50)
    )
    let response = await handler.handle(
      envelope: Self.makeEnvelope(trailingEnter: false)
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: SendCommandPayload.self))
    #expect(payload.input.trailingEnterSent == false)
  }

  @Test func targetNotFoundError() async throws {
    let handler = Self.makeHandler(
      resolveResult: .failure(.notFound("Worktree 'missing' not found."))
    )
    let response = await handler.handle(envelope: Self.makeEnvelope())

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.targetNotFound)
  }

  @Test func targetNotUniqueError() async throws {
    let handler = Self.makeHandler(
      resolveResult: .failure(.notUnique("Worktree 'Prowl' matches 2 worktrees."))
    )
    let response = await handler.handle(envelope: Self.makeEnvelope())

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.targetNotUnique)
  }

  @Test func waitWithNonZeroExitCode() async throws {
    let handler = Self.makeHandler(
      waiterResult: (exitCode: 1, durationMs: 500)
    )
    let response = await handler.handle(envelope: Self.makeEnvelope())

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: SendCommandPayload.self))
    #expect(payload.wait?.exitCode == 1)
    #expect(payload.wait?.durationMs == 500)
  }

  @Test func waitWithNullExitCode() async throws {
    let handler = Self.makeHandler(
      waiterResult: (exitCode: nil, durationMs: 200)
    )
    let response = await handler.handle(envelope: Self.makeEnvelope())

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: SendCommandPayload.self))
    #expect(payload.wait?.exitCode == nil)
  }

  @Test func waitRegistrationHappensBeforeTextDelivery() async throws {
    var continuation: AsyncStream<(exitCode: Int?, durationMs: Int)>.Continuation?

    let handler = SendCommandHandler(
      resolveProvider: { _ in .success(Self.makeTarget()) },
      textDelivery: { _, _, _ in
        continuation?.yield((exitCode: 0, durationMs: 1))
        continuation?.finish()
      },
      waiterProvider: { _, _ in
        AsyncStream { streamContinuation in
          continuation = streamContinuation
        }
      }
    )

    let response = await handler.handle(envelope: Self.makeEnvelope(timeoutSeconds: 1))

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: SendCommandPayload.self))
    #expect(payload.wait?.exitCode == 0)
    #expect(payload.wait?.durationMs == 1)
  }

  @Test func textDeliveryReceivesCorrectArguments() async throws {
    var deliveredText: String?
    var deliveredTrailingEnter: Bool?

    let handler = Self.makeHandler(
      waiterResult: (exitCode: 0, durationMs: 10),
      textDelivery: { _, text, trailingEnter in
        deliveredText = text
        deliveredTrailingEnter = trailingEnter
      }
    )
    _ = await handler.handle(envelope: Self.makeEnvelope(text: "git status", trailingEnter: false))

    #expect(deliveredText == "git status")
    #expect(deliveredTrailingEnter == false)
  }

  @Test func deliveryTargetsResolvedPane() {
    var insertedPaneID: UUID?
    var submittedPaneID: UUID?
    let delivery = CLISendTextDelivery(
      insertText: { paneID, _ in
        insertedPaneID = paneID
        return true
      },
      submitLine: { paneID in
        submittedPaneID = paneID
        return true
      }
    )

    delivery.deliver(to: Self.makeTarget(), text: "echo hi", trailingEnter: true)

    #expect(insertedPaneID == Self.testPaneID)
    #expect(submittedPaneID == Self.testPaneID)
  }

  // MARK: - Capture Tests

  @Test func captureReturnsScreenDiff() async throws {
    let pre = ReadCaptureInput(viewportText: "line1\nline2", screenText: nil)
    let post = ReadCaptureInput(viewportText: "line1\nline2\noutput1\noutput2", screenText: nil)
    var callCount = 0
    let handler = Self.makeHandler(
      waiterResult: (exitCode: 0, durationMs: 10),
      captureProvider: { _ in
        defer { callCount += 1 }
        return callCount == 0 ? pre : post
      }
    )
    let response = await handler.handle(envelope: Self.makeEnvelope(captureOutput: true))

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: SendCommandPayload.self))
    let capture = try #require(payload.capture)
    #expect(capture.lineCount == 2)
    #expect(capture.source == .screenDiff)
    #expect(capture.text == "output1\noutput2")
    #expect(capture.truncated == false)
  }

  @Test func captureStripsEchoedCommand() async throws {
    let pre = ReadCaptureInput(viewportText: "$ ", screenText: nil)
    let post = ReadCaptureInput(viewportText: "$ \necho hello\nhello\n$ ", screenText: nil)
    var callCount = 0
    let handler = Self.makeHandler(
      waiterResult: (exitCode: 0, durationMs: 10),
      captureProvider: { _ in
        defer { callCount += 1 }
        return callCount == 0 ? pre : post
      }
    )
    let response = await handler.handle(
      envelope: Self.makeEnvelope(text: "echo hello", captureOutput: true)
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: SendCommandPayload.self))
    let capture = try #require(payload.capture)
    #expect(capture.text == "hello")
    #expect(capture.lineCount == 1)
  }

  @Test func captureWithEmptyOutput() async throws {
    let snap = ReadCaptureInput(viewportText: "line1\nline2", screenText: nil)
    var callCount = 0
    let handler = Self.makeHandler(
      waiterResult: (exitCode: 0, durationMs: 10),
      captureProvider: { _ in
        defer { callCount += 1 }
        return snap
      }
    )
    let response = await handler.handle(envelope: Self.makeEnvelope(captureOutput: true))

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: SendCommandPayload.self))
    let capture = try #require(payload.capture)
    #expect(capture.text == "")
    #expect(capture.lineCount == 0)
    #expect(capture.truncated == false)
  }

  @Test func captureWithTruncation() async throws {
    let pre = ReadCaptureInput(viewportText: "line1\nline2\nline3", screenText: nil)
    let post = ReadCaptureInput(viewportText: "line1\nline2", screenText: nil)
    var callCount = 0
    let handler = Self.makeHandler(
      waiterResult: (exitCode: 0, durationMs: 10),
      captureProvider: { _ in
        defer { callCount += 1 }
        return callCount == 0 ? pre : post
      }
    )
    let response = await handler.handle(envelope: Self.makeEnvelope(captureOutput: true))

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: SendCommandPayload.self))
    let capture = try #require(payload.capture)
    #expect(capture.truncated == true)
  }

  @Test func captureNilWhenProviderFails() async throws {
    let handler = Self.makeHandler(
      waiterResult: (exitCode: 0, durationMs: 10),
      captureProvider: { _ in nil }
    )
    let response = await handler.handle(envelope: Self.makeEnvelope(captureOutput: true))

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: SendCommandPayload.self))
    #expect(payload.capture == nil)
  }

  @Test func captureNullWhenNotRequested() async throws {
    let handler = Self.makeHandler(
      waiterResult: (exitCode: 0, durationMs: 10)
    )
    let response = await handler.handle(envelope: Self.makeEnvelope(captureOutput: false))

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: SendCommandPayload.self))
    #expect(payload.capture == nil)
  }

  @Test func captureRequiresWaitValidation() async throws {
    let handler = Self.makeHandler()
    let response = await handler.handle(
      envelope: Self.makeEnvelope(wait: false, captureOutput: true)
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.invalidArgument)
  }

  @Test func captureRequiresEnterValidation() async throws {
    let handler = Self.makeHandler(
      waiterResult: (exitCode: 0, durationMs: 10)
    )
    let response = await handler.handle(
      envelope: Self.makeEnvelope(trailingEnter: false, captureOutput: true)
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.invalidArgument)
  }

  @Test func captureWithRepeatedPromptLines() async throws {
    let pre = ReadCaptureInput(viewportText: "$ ", screenText: nil)
    let post = ReadCaptureInput(viewportText: "$ \n$ echo hello\nhello\n$ ", screenText: nil)
    var callCount = 0
    let handler = Self.makeHandler(
      waiterResult: (exitCode: 0, durationMs: 10),
      captureProvider: { _ in
        defer { callCount += 1 }
        return callCount == 0 ? pre : post
      }
    )
    let response = await handler.handle(
      envelope: Self.makeEnvelope(text: "echo hello", captureOutput: true)
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: SendCommandPayload.self))
    let capture = try #require(payload.capture)
    // "$ echo hello" is echoed command, stripped; "hello" is the output; "$ " is trailing prompt (stripped)
    #expect(capture.text == "hello")
    #expect(capture.lineCount == 1)
  }

  @Test func captureUnsupportedWhenNoShellIntegration() async throws {
    // waiterProvider returns nil (no shell integration) → CAPTURE_UNSUPPORTED, not WAIT_TIMEOUT
    let handler = Self.makeHandler(
      waiterResult: nil,  // nil means waiterProvider returns nil stream
      captureProvider: { _ in ReadCaptureInput(viewportText: "$ ", screenText: nil) }
    )
    let response = await handler.handle(
      envelope: Self.makeEnvelope(captureOutput: true)
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.captureUnsupported)
  }

  @Test func captureMultilineOutputWithScreenPadding() async throws {
    // Simulates `ls` output with screen buffer padding (trailing blank lines)
    let pre = ReadCaptureInput(
      viewportText: "$ \n\n\n\n\n",
      screenText: "$ \n\n\n\n\n"
    )
    let post = ReadCaptureInput(
      viewportText: "$ \nls\nfile1.txt\nfile2.txt\ndir1\n$ \n\n\n",
      screenText: "$ \nls\nfile1.txt\nfile2.txt\ndir1\n$ \n\n\n"
    )
    var callCount = 0
    let handler = Self.makeHandler(
      waiterResult: (exitCode: 0, durationMs: 10),
      captureProvider: { _ in
        defer { callCount += 1 }
        return callCount == 0 ? pre : post
      }
    )
    let response = await handler.handle(
      envelope: Self.makeEnvelope(text: "ls", captureOutput: true)
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: SendCommandPayload.self))
    let capture = try #require(payload.capture)
    #expect(capture.text == "file1.txt\nfile2.txt\ndir1")
    #expect(capture.lineCount == 3)
    #expect(capture.truncated == false)
  }
}
