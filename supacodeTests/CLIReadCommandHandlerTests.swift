import Clocks
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct CLIReadCommandHandlerTests {
  private static let paneID = UUID(uuidString: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764")!
  private static let tabID = UUID(uuidString: "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0")!

  private static func makeTarget() -> ReadResolvedTarget {
    ReadResolvedTarget(
      worktreeID: "Prowl:/Users/onevcat/Projects/Prowl",
      worktreeName: "Prowl",
      worktreePath: "/Users/onevcat/Projects/Prowl",
      worktreeRootPath: "/Users/onevcat/Projects/Prowl",
      worktreeKind: .git,
      tabID: tabID,
      tabTitle: "Prowl 1",
      tabSelected: true,
      paneID: paneID,
      paneTitle: "zsh",
      paneCWD: "/Users/onevcat/Projects/Prowl",
      paneFocused: true
    )
  }

  private static func makeEnvelope(
    last: Int? = nil,
    source: ReadInputSource = .viewport
  ) -> CommandEnvelope {
    CommandEnvelope(
      output: .json,
      command: .read(ReadInput(selector: .none, last: last, source: source))
    )
  }

  @Test func snapshotUsesViewportText() async throws {
    let handler = ReadCommandHandler(
      resolveProvider: { _ in .success(Self.makeTarget()) },
      captureProvider: { _ in
        ReadCaptureInput(
          viewportText: "line-1\nline-2",
          screenText: "old\nline-1\nline-2"
        )
      }
    )

    let response = await handler.handle(envelope: Self.makeEnvelope())

    #expect(response.ok)
    #expect(response.command == "read")
    #expect(response.schemaVersion == "prowl.cli.read.v1")
    let payload = try #require(try response.data?.decode(as: ReadCommandPayload.self))
    #expect(payload.mode == .snapshot)
    #expect(payload.last == nil)
    #expect(payload.source == .screen)
    #expect(payload.truncated == false)
    #expect(payload.lineCount == 2)
    #expect(payload.text == "line-1\nline-2")
  }

  @Test func detectionSnapshotUsesExactDetectorInput() async throws {
    let handler = ReadCommandHandler(
      resolveProvider: { _ in .success(Self.makeTarget()) },
      captureProvider: { request in
        #expect(request.source == .detection)
        return ReadCaptureInput(detectionText: "active-line-1\nactive-line-2\n")
      }
    )

    let response = await handler.handle(envelope: Self.makeEnvelope(source: .detection))

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: ReadCommandPayload.self))
    #expect(payload.mode == .snapshot)
    #expect(payload.source == .detection)
    #expect(payload.truncated == false)
    #expect(payload.lineCount == 3)
    #expect(payload.text == "active-line-1\nactive-line-2\n")
  }

  @Test func detectionLastUsesOnlyDetectorInput() async throws {
    let handler = ReadCommandHandler(
      resolveProvider: { _ in .success(Self.makeTarget()) },
      captureProvider: { _ in ReadCaptureInput(detectionText: "one\ntwo\nthree") }
    )

    let response = await handler.handle(envelope: Self.makeEnvelope(last: 2, source: .detection))

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: ReadCommandPayload.self))
    #expect(payload.mode == .last)
    #expect(payload.source == .detection)
    #expect(payload.truncated == false)
    #expect(payload.lineCount == 2)
    #expect(payload.text == "two\nthree")
  }

  @Test func detectionRejectsMismatchedCaptureSource() async {
    let handler = ReadCommandHandler(
      resolveProvider: { _ in .success(Self.makeTarget()) },
      captureProvider: { _ in ReadCaptureInput(viewportText: "viewport", screenText: nil) }
    )

    let response = await handler.handle(envelope: Self.makeEnvelope(source: .detection))

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.readFailed)
  }

  @Test func readInputWithoutSourceDecodesAsViewport() throws {
    let encoded = try JSONEncoder().encode(ReadInput())
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "source")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let input = try JSONDecoder().decode(ReadInput.self, from: legacyData)

    #expect(input.source == .viewport)
  }

  @Test func snapshotSucceedsWhenScreenCaptureUnavailable() async throws {
    let handler = ReadCommandHandler(
      resolveProvider: { _ in .success(Self.makeTarget()) },
      captureProvider: { _ in
        ReadCaptureInput(
          viewportText: "line-1\nline-2",
          screenText: nil
        )
      }
    )

    let response = await handler.handle(envelope: Self.makeEnvelope())

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: ReadCommandPayload.self))
    #expect(payload.mode == .snapshot)
    #expect(payload.source == .screen)
    #expect(payload.truncated == false)
    #expect(payload.lineCount == 2)
    #expect(payload.text == "line-1\nline-2")
  }

  @Test func lastUsesViewportWhenEnoughLines() async throws {
    let handler = ReadCommandHandler(
      resolveProvider: { _ in .success(Self.makeTarget()) },
      captureProvider: { _ in
        ReadCaptureInput(
          viewportText: "a\nb\nc\nd",
          screenText: "x\na\nb\nc\nd"
        )
      }
    )

    let response = await handler.handle(envelope: Self.makeEnvelope(last: 2))

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: ReadCommandPayload.self))
    #expect(payload.mode == .last)
    #expect(payload.last == 2)
    #expect(payload.source == .screen)
    #expect(payload.truncated == false)
    #expect(payload.lineCount == 2)
    #expect(payload.text == "c\nd")
  }

  @Test func lastUsesScrollbackWhenViewportInsufficient() async throws {
    let handler = ReadCommandHandler(
      resolveProvider: { _ in .success(Self.makeTarget()) },
      captureProvider: { _ in
        ReadCaptureInput(
          viewportText: "c\nd",
          screenText: "a\nb\nc\nd"
        )
      }
    )

    let response = await handler.handle(envelope: Self.makeEnvelope(last: 3))

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: ReadCommandPayload.self))
    #expect(payload.source == .scrollback)
    #expect(payload.truncated == false)
    #expect(payload.lineCount == 3)
    #expect(payload.text == "b\nc\nd")
  }

  @Test func lastReturnsFullBufferWithoutTruncationWhenHistoryShorterThanRequest() async throws {
    let handler = ReadCommandHandler(
      resolveProvider: { _ in .success(Self.makeTarget()) },
      captureProvider: { _ in
        ReadCaptureInput(
          viewportText: "three\nfour",
          screenText: "one\ntwo\nthree\nfour"
        )
      }
    )

    let response = await handler.handle(envelope: Self.makeEnvelope(last: 10))

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: ReadCommandPayload.self))
    #expect(payload.source == .scrollback)
    // The full screen+scrollback buffer was retrievable and holds only 4 lines, so the
    // response contains everything the pane retains. Fewer lines than `--last 10` requested
    // does not mean content was lost, so it must not be flagged truncated.
    #expect(payload.truncated == false)
    #expect(payload.lineCount == 4)
    #expect(payload.text == "one\ntwo\nthree\nfour")
  }

  @Test func lastFallsBackToViewportWhenScreenCaptureUnavailable() async throws {
    let handler = ReadCommandHandler(
      resolveProvider: { _ in .success(Self.makeTarget()) },
      captureProvider: { _ in
        ReadCaptureInput(
          viewportText: "three\nfour",
          screenText: nil
        )
      }
    )

    let response = await handler.handle(envelope: Self.makeEnvelope(last: 10))

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: ReadCommandPayload.self))
    #expect(payload.source == .mixed)
    #expect(payload.truncated == true)
    #expect(payload.lineCount == 2)
    #expect(payload.text == "three\nfour")
  }

  @Test func lastPrefersViewportWhenScreenHasFewerLines() async throws {
    let handler = ReadCommandHandler(
      resolveProvider: { _ in .success(Self.makeTarget()) },
      captureProvider: { _ in
        ReadCaptureInput(
          viewportText: "b\nc\nd",
          screenText: "c\nd"
        )
      }
    )

    let response = await handler.handle(envelope: Self.makeEnvelope(last: 5))

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: ReadCommandPayload.self))
    #expect(payload.source == .mixed)
    #expect(payload.truncated == true)
    #expect(payload.lineCount == 3)
    #expect(payload.text == "b\nc\nd")
  }

  @Test func trailingNewlineCountsAsExtraLine() async throws {
    let handler = ReadCommandHandler(
      resolveProvider: { _ in .success(Self.makeTarget()) },
      captureProvider: { _ in
        ReadCaptureInput(
          viewportText: "done\n",
          screenText: "done\n"
        )
      }
    )

    let response = await handler.handle(envelope: Self.makeEnvelope())

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: ReadCommandPayload.self))
    #expect(payload.lineCount == 2)
    #expect(payload.text == "done\n")
  }

  @Test func targetNotFoundMapsToContractCode() async {
    let handler = ReadCommandHandler(
      resolveProvider: { _ in .failure(.notFound("Pane missing")) },
      captureProvider: { _ in nil }
    )

    let response = await handler.handle(envelope: Self.makeEnvelope())

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.targetNotFound)
  }

  @Test func targetNotUniqueMapsToContractCode() async {
    let handler = ReadCommandHandler(
      resolveProvider: { _ in .failure(.notUnique("Ambiguous worktree")) },
      captureProvider: { _ in nil }
    )

    let response = await handler.handle(envelope: Self.makeEnvelope(last: 3))

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.targetNotUnique)
  }

  @Test func captureFailureReturnsReadFailed() async {
    let handler = ReadCommandHandler(
      resolveProvider: { _ in .success(Self.makeTarget()) },
      captureProvider: { _ in nil }
    )

    let response = await handler.handle(envelope: Self.makeEnvelope())

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.readFailed)
  }

  // MARK: - Wait-for-stable polling

  @Test func waitStableReturnsWhenOutputSettles() async throws {
    let clock = TestClock()
    let capture = CaptureSequence(["ready"])
    let handler = ReadCommandHandler(
      resolveProvider: { _ in .success(Self.makeTarget()) },
      captureProvider: { _ in capture.next() },
      clock: clock
    )

    let task = Task {
      await handler.handle(
        envelope: Self.makeWaitStableEnvelope(intervalMs: 100, periodMs: 300, timeoutSeconds: 1)
      )
    }
    await Self.drive(clock, steps: 15)
    let response = await task.value

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: ReadCommandPayload.self))
    #expect(payload.text == "ready")
    #expect(payload.stabilized == true)
    // 1 initial sample + 3 consecutive unchanged samples to cover the 300ms / 100ms streak.
    #expect(payload.samples == 4)
    #expect(payload.waitedMs == 300)
  }

  @Test func waitStableReturnsLatestContentAfterChanges() async throws {
    let clock = TestClock()
    let capture = CaptureSequence(["a", "ab", "abc"])
    let handler = ReadCommandHandler(
      resolveProvider: { _ in .success(Self.makeTarget()) },
      captureProvider: { _ in capture.next() },
      clock: clock
    )

    let task = Task {
      await handler.handle(
        envelope: Self.makeWaitStableEnvelope(intervalMs: 100, periodMs: 300, timeoutSeconds: 1)
      )
    }
    await Self.drive(clock, steps: 15)
    let response = await task.value

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: ReadCommandPayload.self))
    #expect(payload.text == "abc")
    #expect(payload.stabilized == true)
  }

  @Test func waitStableTimesOutWhenOutputKeepsChanging() async throws {
    let clock = TestClock()
    let counter = Counter()
    let handler = ReadCommandHandler(
      resolveProvider: { _ in .success(Self.makeTarget()) },
      captureProvider: { _ in
        ReadCaptureInput(viewportText: "v\(counter.bump())", screenText: nil)
      },
      clock: clock
    )

    let task = Task {
      await handler.handle(
        envelope: Self.makeWaitStableEnvelope(intervalMs: 100, periodMs: 300, timeoutSeconds: 1)
      )
    }
    await Self.drive(clock, steps: 15)
    let response = await task.value

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: ReadCommandPayload.self))
    #expect(payload.stabilized == false)
    // timeout 1000ms / 100ms interval = 10 sleeps, plus the initial sample.
    #expect(payload.samples == 11)
    #expect(payload.waitedMs == 1000)
    #expect(payload.text == "v11")
  }

  // MARK: - Wait-for-stable helpers

  private static func makeWaitStableEnvelope(
    last: Int? = nil,
    intervalMs: Int,
    periodMs: Int,
    timeoutSeconds: Int
  ) -> CommandEnvelope {
    CommandEnvelope(
      output: .json,
      command: .read(
        ReadInput(
          selector: .none,
          last: last,
          waitStable: true,
          stableIntervalMs: intervalMs,
          stablePeriodMs: periodMs,
          waitTimeoutSeconds: timeoutSeconds
        ))
    )
  }

  /// Yield to let the handler reach its first sleep, then advance the test clock one interval at a
  /// time so each `clock.sleep(for:)` wakes and the poll loop makes progress.
  private static func drive(_ clock: TestClock<Duration>, steps: Int) async {
    await Task.yield()
    for _ in 0..<steps {
      await clock.advance(by: .milliseconds(100))
      await Task.yield()
    }
  }

  @MainActor
  private final class CaptureSequence {
    private let values: [String]
    private var index = 0

    init(_ values: [String]) {
      self.values = values
    }

    func next() -> ReadCaptureInput {
      let text = values[Swift.min(index, values.count - 1)]
      index += 1
      return ReadCaptureInput(viewportText: text, screenText: nil)
    }
  }

  @MainActor
  private final class Counter {
    private var value = 0

    func bump() -> Int {
      value += 1
      return value
    }
  }
}
