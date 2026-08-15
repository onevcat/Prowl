import Clocks
import Darwin
import Foundation
import Testing

@testable import supacode

@MainActor
struct HerdrInputContextTests {
  @Test func detectsExactHerdrForegroundProcess() {
    let job = ForegroundJob(
      processGroupID: 42,
      processes: [
        ForegroundProcess(
          pid: 42,
          name: "herdr",
          argv0: "/opt/homebrew/bin/herdr",
          cmdline: "/opt/homebrew/bin/herdr"
        )
      ]
    )

    #expect(HerdrProcessDetector.isHerdr(job))
  }

  @Test func rejectsProcessWhoseArgumentsOnlyMentionHerdr() {
    let job = ForegroundJob(
      processGroupID: 42,
      processes: [
        ForegroundProcess(
          pid: 42,
          name: "zsh",
          argv0: "/bin/zsh",
          cmdline: "zsh ./scripts/test-herdr.sh"
        )
      ]
    )

    #expect(!HerdrProcessDetector.isHerdr(job))
  }

  @Test func resolvesXDGSocketBeforeHomeFallback() {
    let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)

    #expect(
      HerdrSocketPathResolver.defaultPath(
        environment: ["XDG_CONFIG_HOME": "/tmp/config"],
        homeDirectory: home
      ) == "/tmp/config/herdr/herdr.sock"
    )
    #expect(
      HerdrSocketPathResolver.defaultPath(environment: [:], homeDirectory: home)
        == "/Users/example/.config/herdr/herdr.sock"
    )
  }

  @Test func decodesPaneCurrentWithAgentAsChatContext() throws {
    let response = try JSONDecoder().decode(
      HerdrResponseEnvelope.self,
      from: Data(
        #"{"id":"clean-current","result":{"type":"pane_current","pane":{"pane_id":"w1:p2","agent":"codex","agent_status":"working","future_field":true}}}"#
          .utf8
      )
    )

    #expect(response.currentPane?.paneID == "w1:p2")
    #expect(response.currentPane?.inputContext == .chatAgent)
  }

  @Test func decodesPaneCurrentWithoutAgentAsCommandContext() throws {
    let response = try JSONDecoder().decode(
      HerdrResponseEnvelope.self,
      from: Data(
        #"{"id":"clean-current","result":{"type":"pane_current","pane":{"pane_id":"w1:p3","agent_status":"unknown"}}}"#
          .utf8
      )
    )

    #expect(response.currentPane?.inputContext == .commandLike)
  }

  @Test func acceptsSupportedHerdrProtocol() throws {
    let response = try JSONDecoder().decode(
      HerdrResponseEnvelope.self,
      from: Data(
        #"{"id":"clean-protocol","result":{"type":"pong","version":"0.1.0","protocol":19,"future_field":true}}"#.utf8
      )
    )

    try HerdrProtocolCompatibility.validate(response)
  }

  @Test func rejectsUnsupportedHerdrProtocol() throws {
    let response = try JSONDecoder().decode(
      HerdrResponseEnvelope.self,
      from: Data(
        #"{"id":"clean-protocol","result":{"type":"pong","version":"0.2.0","protocol":20}}"#.utf8
      )
    )

    #expect(
      throws: HerdrSocketError.unsupportedProtocol(expected: 19, actual: 20)
    ) {
      try HerdrProtocolCompatibility.validate(response)
    }
  }

  @Test func adapterRetriesConnectionFailureWithInjectedClock() async {
    let clock = TestClock()
    let attemptCount = LockIsolated(0)
    let client = HerdrInputContextClient(
      currentPane: {
        attemptCount.withValue { $0 += 1 }
        throw HerdrSocketError.connectionFailed(ECONNREFUSED)
      },
      events: { AsyncStream { $0.finish() } }
    )
    let adapter = HerdrInputContextAdapter(client: client, clock: clock) { _ in }

    adapter.start()
    await Task.yield()
    await Task.yield()
    #expect(attemptCount.value == 1)

    await clock.advance(by: .milliseconds(249))
    await Task.yield()
    #expect(attemptCount.value == 1)

    await clock.advance(by: .milliseconds(1))
    await Task.yield()
    await Task.yield()
    #expect(attemptCount.value == 2)
    adapter.stop()
  }

  @Test func adapterStopsAfterProtocolMismatch() async {
    let clock = TestClock()
    let attemptCount = LockIsolated(0)
    let client = HerdrInputContextClient(
      currentPane: {
        attemptCount.withValue { $0 += 1 }
        throw HerdrSocketError.unsupportedProtocol(expected: 19, actual: 20)
      },
      events: { AsyncStream { $0.finish() } }
    )
    let adapter = HerdrInputContextAdapter(client: client, clock: clock) { _ in }

    adapter.start()
    await Task.yield()
    await Task.yield()

    #expect(attemptCount.value == 1)
    #expect(!adapter.isRunning)
    await clock.advance(by: .seconds(2))
    await Task.yield()
    #expect(attemptCount.value == 1)

    adapter.start()
    await Task.yield()
    #expect(attemptCount.value == 1)

    adapter.resetAfterHerdrExit()
    adapter.start()
    await Task.yield()
    await Task.yield()
    #expect(attemptCount.value == 2)
    adapter.stop()
  }
}
