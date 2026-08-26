import Clocks
import ConcurrencyExtras
import Darwin
import Foundation
import Testing

@testable import supacode

@Suite(.serialized)
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
        #"{"id":"clean-current","result":{"type":"pane_current","pane":{"pane_id":"w1:p2","agent":"codex","agent_status":"done","future_field":true}}}"#
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
        #"{"id":"clean-current","result":{"type":"pane_current","pane":{"pane_id":"w1:p3","agent_status":"working"}}}"#
          .utf8
      )
    )

    #expect(response.currentPane?.inputContext == .commandLike)
  }

  @Test func decodesPaneProcessInfoWithForegroundApplication() throws {
    let response = try JSONDecoder().decode(
      HerdrResponseEnvelope.self,
      from: Data(
        #"{"id":"process-info","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","shell_pid":10,"foreground_process_group_id":20,"foreground_processes":[{"pid":20,"name":"lazygit","argv0":"lazygit","cwd":"/Users/yam/Developer/Prowl"}]}}}"#
          .utf8
      )
    )

    #expect(response.paneProcessInfo?.paneID == "w1:p1")
    #expect(response.paneProcessInfo?.foregroundProcesses.first?.name == "lazygit")
    #expect(response.paneProcessInfo?.foregroundProcessGroupID == 20)
  }

  @Test(
    arguments: [
      "workspace.focused",
      "tab.focused",
      "pane.focused",
      "pane.updated",
      "pane.agent_detected",
      "pane.exited",
      "pane.closed",
      "pane.moved",
    ]
  )
  func decodesSubscribedLifecycleEvent(eventName: String) throws {
    let event = try JSONDecoder().decode(
      HerdrEventEnvelope.self,
      from: Data(#"{"event":"\#(eventName)","data":{"future_field":true}}"#.utf8)
    )

    #expect(event.event == eventName)
  }

  @Test func decodesAgentReleasedEventPayload() throws {
    let event = try JSONDecoder().decode(
      HerdrEventEnvelope.self,
      from: Data(
        #"{"event":"pane.agent_detected","data":{"pane_id":"w1:p2","released":true}}"#.utf8
      )
    )

    #expect(event.event == "pane.agent_detected")
  }

  @Test func acceptsSupportedHerdrProtocol21() throws {
    let response = try JSONDecoder().decode(
      HerdrResponseEnvelope.self,
      from: Data(
        #"{"id":"clean-protocol","result":{"type":"pong","version":"0.8.2","protocol":21,"future_field":true}}"#
          .utf8
      )
    )

    try HerdrProtocolCompatibility.validate(response)
  }

  @Test func rejectsLegacyHerdrProtocol20() throws {
    let response = try JSONDecoder().decode(
      HerdrResponseEnvelope.self,
      from: Data(
        #"{"id":"clean-protocol","result":{"type":"pong","version":"0.8.2","protocol":20}}"#.utf8
      )
    )

    #expect(
      throws: HerdrSocketError.unsupportedProtocol(supported: 21...21, actual: 20)
    ) {
      try HerdrProtocolCompatibility.validate(response)
    }
  }

  @Test func rejectsUnsupportedFutureHerdrProtocol() throws {
    let response = try JSONDecoder().decode(
      HerdrResponseEnvelope.self,
      from: Data(
        #"{"id":"clean-protocol","result":{"type":"pong","version":"0.9.0","protocol":22}}"#.utf8
      )
    )

    #expect(
      throws: HerdrSocketError.unsupportedProtocol(supported: 21...21, actual: 22)
    ) {
      try HerdrProtocolCompatibility.validate(response)
    }
  }

  @Test func currentPaneUsesASeparateConnectionAfterProtocolCheck() async throws {
    let server = try HerdrSingleRequestTestServer(
      exchanges: [
        .init(
          expectedMethod: "ping",
          response:
            #"{"id":"prowl-clean-protocol","result":{"type":"pong","version":"0.8.2","protocol":21}}"#
        ),
        .init(
          expectedMethod: "pane.current",
          response:
            #"{"id":"prowl-clean-current","result":{"type":"pane_current","pane":{"pane_id":"w1:p2","agent":"codex","agent_status":"idle"}}}"#
        ),
      ]
    )
    server.start()
    defer { server.stop() }

    let pane = try await HerdrSocketClient(socketPath: server.socketPath).currentPane()

    #expect(pane == HerdrPaneInfo(paneID: "w1:p2", agent: "codex", agentStatus: "idle"))
    #expect(server.failureDescription == nil)
  }

  @Test func eventSubscriptionUsesASeparateConnectionAfterProtocolCheck() async throws {
    let server = try HerdrSingleRequestTestServer(
      exchanges: [
        .init(
          expectedMethod: "ping",
          response:
            #"{"id":"prowl-clean-protocol","result":{"type":"pong","version":"0.8.2","protocol":21}}"#
        ),
        .init(
          expectedMethod: "events.subscribe",
          response:
            #"{"id":"prowl-clean-events","result":{"type":"subscription_started"}}"#,
          expectedSubscriptionTypes: [
            "workspace.focused",
            "tab.focused",
            "pane.focused",
            "pane.updated",
            "pane.agent_detected",
            "pane.exited",
            "pane.closed",
            "pane.moved",
          ],
          keepsConnectionOpen: true
        ),
      ]
    )
    server.start()
    defer { server.stop() }

    var firstState: HerdrEventStreamState?
    for await state in HerdrSocketClient(socketPath: server.socketPath).events() {
      firstState = state
      break
    }

    guard case .subscribed = firstState else {
      Issue.record("Expected Herdr subscription to start, got \(String(describing: firstState))")
      return
    }
    #expect(server.failureDescription == nil)
  }

  @Test func terminalChromeSubscriptionUsesPaneIDsAndCancelsItsSocket() async throws {
    let server = try HerdrSingleRequestTestServer(
      exchanges: [
        .init(
          expectedMethod: "events.subscribe",
          response: #"{"id":"prowl-clean-events","result":{"type":"subscription_started"}}"#,
          expectedSubscriptionTypes: [
            "workspace.created", "workspace.updated", "workspace.metadata_updated", "workspace.renamed",
            "workspace.moved",
            "workspace.closed", "workspace.focused", "workspace.reordered", "worktree.created", "worktree.opened",
            "worktree.removed", "tab.created",
            "tab.renamed", "tab.moved", "tab.closed", "tab.focused", "pane.created",
            "pane.updated", "pane.agent_detected", "pane.moved", "pane.focused", "pane.closed",
            "pane.exited", "layout.updated", "pane.agent_status_changed",
          ],
          keepsConnectionOpen: true
        )
      ]
    )
    server.start()
    defer { server.stop() }

    let subscription = try await HerdrSocketClient(socketPath: server.socketPath)
      .terminalChromeEventSubscription(paneIDs: ["w1:p1"])
    subscription.cancel()

    #expect(server.waitForClientDisconnect(timeout: .now() + .seconds(1)))
  }

  @Test func terminalChromeSnapshotUsesProtocolFromTheSingleBusinessResponse() async throws {
    let server = try HerdrSingleRequestTestServer(
      exchanges: [
        .init(
          expectedMethod: "session.snapshot",
          response:
            #"{"id":"prowl-herdr-sidebar-snapshot","result":{"type":"session_snapshot","snapshot":{"version":"0.8.2","protocol":21,"workspaces":[],"tabs":[],"panes":[],"layouts":[],"agents":[]}}}"#
        )
      ]
    )
    server.start()
    defer { server.stop() }

    let snapshot = try await HerdrSocketClient(socketPath: server.socketPath).sessionSnapshot()

    #expect(snapshot.protocolVersion == 21)
    #expect(server.failureDescription == nil)
  }

  @Test func terminalChromeProcessInfoUsesPaneProcessInfoRequest() async throws {
    let server = try HerdrSingleRequestTestServer(
      exchanges: [
        .init(
          expectedMethod: "pane.process_info",
          response:
            #"{"id":"prowl-herdr-pane-process-info","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","foreground_processes":[]}}}"#
        )
      ]
    )
    server.start()
    defer { server.stop() }

    let processInfo = try await HerdrSocketClient(socketPath: server.socketPath)
      .paneProcessInfo(paneID: "w1:p1")

    #expect(processInfo.paneID == "w1:p1")
    #expect(server.failureDescription == nil)
  }

  @Test func terminalChromeFocusSendsOnlyTheFocusRequest() async throws {
    let server = try HerdrSingleRequestTestServer(
      exchanges: [
        .init(
          expectedMethod: "tab.focus",
          response: #"{"id":"prowl-herdr-sidebar-focus-tab","result":{"type":"ok"}}"#
        )
      ]
    )
    server.start()
    defer { server.stop() }

    try await HerdrSocketClient(socketPath: server.socketPath).focusTab("w1:t1")

    #expect(server.failureDescription == nil)
  }

  @Test func terminalChromeSnapshotRejectsUnsupportedProtocolFromBusinessResponse() async throws {
    let server = try HerdrSingleRequestTestServer(
      exchanges: [
        .init(
          expectedMethod: "session.snapshot",
          response:
            #"{"id":"prowl-herdr-sidebar-snapshot","result":{"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"workspaces":[],"tabs":[],"panes":[],"layouts":[],"agents":[]}}}"#
        )
      ]
    )
    server.start()
    defer { server.stop() }

    await #expect(
      throws: HerdrSocketError.unsupportedProtocol(supported: 21...21, actual: 22)
    ) {
      try await HerdrSocketClient(socketPath: server.socketPath).sessionSnapshot()
    }
    #expect(server.failureDescription == nil)
  }

  @Test func adapterRetriesConnectionFailureWithInjectedClock() async {
    let clock = TestClock()
    let attemptCount = LockIsolated(0)
    let paneContextCount = LockIsolated(0)
    let client = HerdrInputContextClient(
      currentPane: {
        attemptCount.withValue { $0 += 1 }
        throw HerdrSocketError.connectionFailed(ECONNREFUSED)
      },
      events: { AsyncStream { $0.finish() } }
    )
    let adapter = HerdrInputContextAdapter(client: client, clock: clock) { _ in
      paneContextCount.withValue { $0 += 1 }
    }

    adapter.start()
    await waitUntil { attemptCount.value == 1 }
    await Task.megaYield()
    #expect(attemptCount.value == 1)

    await clock.advance(by: .milliseconds(249))
    #expect(attemptCount.value == 1)

    await clock.advance(by: .milliseconds(1))
    await waitUntil { attemptCount.value == 2 }
    #expect(attemptCount.value == 2)
    #expect(paneContextCount.value == 0)
    adapter.stop()
  }

  @Test func adapterDoesNotPublishPaneAfterDecodeFailure() async {
    let clock = TestClock()
    let attemptCount = LockIsolated(0)
    let paneContextCount = LockIsolated(0)
    let client = HerdrInputContextClient(
      currentPane: {
        attemptCount.withValue { $0 += 1 }
        throw HerdrSocketError.invalidResponse
      },
      events: { AsyncStream { $0.finish() } }
    )
    let adapter = HerdrInputContextAdapter(client: client, clock: clock) { _ in
      paneContextCount.withValue { $0 += 1 }
    }

    adapter.start()
    await waitUntil { attemptCount.value == 1 }

    #expect(paneContextCount.value == 0)
    adapter.stop()
  }

  @Test func adapterStopsAfterProtocolMismatch() async {
    let clock = TestClock()
    let attemptCount = LockIsolated(0)
    let compatibilityFailures = LockIsolated<[HerdrSocketError]>([])
    let paneContextCount = LockIsolated(0)
    let client = HerdrInputContextClient(
      currentPane: {
        attemptCount.withValue { $0 += 1 }
        throw HerdrSocketError.unsupportedProtocol(supported: 21...21, actual: 22)
      },
      events: { AsyncStream { $0.finish() } }
    )
    let adapter = HerdrInputContextAdapter(
      client: client,
      clock: clock,
      onCompatibilityFailure: { error in
        compatibilityFailures.withValue { $0.append(error) }
      },
      onPaneContext: { _ in
        paneContextCount.withValue { $0 += 1 }
      }
    )

    adapter.start()
    await waitUntil { attemptCount.value == 1 && !adapter.isRunning }

    #expect(attemptCount.value == 1)
    #expect(!adapter.isRunning)
    #expect(
      compatibilityFailures.value == [
        .unsupportedProtocol(supported: 21...21, actual: 22)
      ]
    )
    #expect(paneContextCount.value == 0)
    await clock.advance(by: .seconds(2))
    #expect(attemptCount.value == 1)

    adapter.start()
    await Task.yield()
    #expect(attemptCount.value == 1)

    adapter.resetAfterHerdrExit()
    adapter.start()
    await waitUntil { attemptCount.value == 2 }
    #expect(attemptCount.value == 2)
    adapter.stop()
  }

  @Test func adapterDoesNotPublishStalePaneAfterStop() async throws {
    let paneContinuation = LockIsolated<CheckedContinuation<HerdrPaneInfo, Never>?>(nil)
    let receivedPanes = LockIsolated<[HerdrPaneInfo]>([])
    let client = HerdrInputContextClient(
      currentPane: {
        await withCheckedContinuation { continuation in
          paneContinuation.setValue(continuation)
        }
      },
      events: { AsyncStream { $0.finish() } }
    )
    let adapter = HerdrInputContextAdapter(client: client, clock: ImmediateClock()) { pane in
      receivedPanes.withValue { $0.append(pane) }
    }

    adapter.start()
    await waitUntil { paneContinuation.value != nil }
    adapter.stop()
    let continuation = try #require(
      paneContinuation.withValue { value in
        defer { value = nil }
        return value
      }
    )
    continuation.resume(
      returning: HerdrPaneInfo(paneID: "w1:stale", agent: "codex", agentStatus: "working")
    )
    for _ in 0..<20 {
      await Task.yield()
    }

    #expect(receivedPanes.value.isEmpty)
  }

  @Test func adapterRefreshesCurrentPaneAfterSubscriptionStarts() async {
    let clock = TestClock()
    let refreshCount = LockIsolated(0)
    let client = HerdrInputContextClient(
      currentPane: {
        refreshCount.withValue { $0 += 1 }
        return HerdrPaneInfo(paneID: "w1:p1", agent: nil, agentStatus: nil)
      },
      events: {
        AsyncStream { continuation in
          continuation.yield(.subscribed)
          continuation.yield(.disconnected(.connectionClosed))
          continuation.finish()
        }
      }
    )
    let adapter = HerdrInputContextAdapter(client: client, clock: clock) { _ in }

    adapter.start()
    await waitUntil { refreshCount.value == 2 }

    #expect(refreshCount.value == 2)
    adapter.stop()
  }

  @Test func adapterRefreshesWhenBufferedEventReplacesSubscriptionState() async {
    let refreshCount = LockIsolated(0)
    let client = HerdrInputContextClient(
      currentPane: {
        refreshCount.withValue { $0 += 1 }
        return HerdrPaneInfo(paneID: "w1:p1", agent: nil, agentStatus: nil)
      },
      events: {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
          continuation.yield(.subscribed)
          continuation.yield(.event(HerdrEventEnvelope(event: "pane_updated")))
        }
      }
    )
    let adapter = HerdrInputContextAdapter(client: client, clock: ImmediateClock()) { _ in }

    adapter.start()
    await waitUntil { refreshCount.value == 2 }

    #expect(refreshCount.value == 2)
    adapter.stop()
  }

  @Test func adapterPollsCurrentPaneWhenSubscriptionHasNoEvents() async {
    let clock = TestClock()
    let refreshCount = LockIsolated(0)
    let currentPane = LockIsolated(
      HerdrPaneInfo(paneID: "w1:p1", agent: nil, agentStatus: nil)
    )
    let publishedPaneIDs = LockIsolated<[String]>([])
    let eventContinuation = LockIsolated<AsyncStream<HerdrEventStreamState>.Continuation?>(nil)
    let client = HerdrInputContextClient(
      currentPane: {
        refreshCount.withValue { $0 += 1 }
        return currentPane.value
      },
      events: {
        AsyncStream { continuation in
          eventContinuation.setValue(continuation)
          continuation.yield(.subscribed)
        }
      }
    )
    let adapter = HerdrInputContextAdapter(client: client, clock: clock) { pane in
      publishedPaneIDs.withValue { $0.append(pane.paneID) }
    }

    adapter.start()
    await waitUntil { refreshCount.value == 2 }
    #expect(publishedPaneIDs.value == ["w1:p1"])

    currentPane.setValue(HerdrPaneInfo(paneID: "w2:p7", agent: "codex", agentStatus: "idle"))
    await clock.advance(by: .milliseconds(100))
    await waitUntil { refreshCount.value == 3 }

    #expect(refreshCount.value == 3)
    #expect(publishedPaneIDs.value == ["w1:p1", "w2:p7"])
    adapter.stop()
    eventContinuation.value?.finish()
  }

  @Test func adapterDoesNotRepublishUnchangedPaneContext() async {
    let clock = TestClock()
    let refreshCount = LockIsolated(0)
    let publishedContextCount = LockIsolated(0)
    let eventContinuation = LockIsolated<AsyncStream<HerdrEventStreamState>.Continuation?>(nil)
    let client = HerdrInputContextClient(
      currentPane: {
        refreshCount.withValue { $0 += 1 }
        return HerdrPaneInfo(paneID: "w1:p1", agent: "codex", agentStatus: "working")
      },
      events: {
        AsyncStream { continuation in
          eventContinuation.setValue(continuation)
          continuation.yield(.subscribed)
        }
      }
    )
    let adapter = HerdrInputContextAdapter(client: client, clock: clock) { _ in
      publishedContextCount.withValue { $0 += 1 }
    }

    adapter.start()
    await waitUntil { refreshCount.value == 2 }
    await clock.advance(by: .milliseconds(100))
    await waitUntil { refreshCount.value == 3 }

    #expect(publishedContextCount.value == 1)
    adapter.stop()
    eventContinuation.value?.finish()
  }

  @Test func adapterReappliesCachedPaneContextWithoutRefreshingSocket() async {
    let refreshCount = LockIsolated(0)
    let publishedPaneIDs = LockIsolated<[String]>([])
    let eventContinuation = LockIsolated<AsyncStream<HerdrEventStreamState>.Continuation?>(nil)
    let client = HerdrInputContextClient(
      currentPane: { _ in
        refreshCount.withValue { $0 += 1 }
        return HerdrPaneInfo(paneID: "w1:p1", agent: "codex", agentStatus: "working")
      },
      events: {
        AsyncStream { continuation in
          eventContinuation.setValue(continuation)
          continuation.yield(.subscribed)
        }
      }
    )
    let adapter = HerdrInputContextAdapter(client: client) { pane in
      publishedPaneIDs.withValue { $0.append(pane.paneID) }
    }

    adapter.start()
    await waitUntil { refreshCount.value == 2 && publishedPaneIDs.value == ["w1:p1"] }
    adapter.reapplyLastPaneContext()

    #expect(refreshCount.value == 2)
    #expect(publishedPaneIDs.value == ["w1:p1", "w1:p1"])
    adapter.stop()
    eventContinuation.value?.finish()
  }

  @Test func adapterOnlyValidatesProtocolForConnectionStartup() async {
    let clock = TestClock()
    let validationFlags = LockIsolated<[Bool]>([])
    let eventContinuation = LockIsolated<AsyncStream<HerdrEventStreamState>.Continuation?>(nil)
    let client = HerdrInputContextClient(
      currentPane: { validateProtocol in
        validationFlags.withValue { $0.append(validateProtocol) }
        return HerdrPaneInfo(paneID: "w1:p1", agent: nil, agentStatus: nil)
      },
      events: {
        AsyncStream { continuation in
          eventContinuation.setValue(continuation)
          continuation.yield(.subscribed)
        }
      }
    )
    let adapter = HerdrInputContextAdapter(client: client, clock: clock) { _ in }

    adapter.start()
    await waitUntil { validationFlags.value.count == 2 }
    await clock.advance(by: .milliseconds(100))
    await waitUntil { validationFlags.value.count == 3 }

    #expect(validationFlags.value == [true, false, false])
    adapter.stop()
    eventContinuation.value?.finish()
  }

  @Test func adapterCoalescesImmediateRefreshWithStartupRequest() async throws {
    let requestContinuation = LockIsolated<CheckedContinuation<HerdrPaneInfo, Never>?>(nil)
    let requestCount = LockIsolated(0)
    let client = HerdrInputContextClient(
      currentPane: { _ in
        requestCount.withValue { $0 += 1 }
        return await withCheckedContinuation { continuation in
          requestContinuation.setValue(continuation)
        }
      },
      events: { AsyncStream { $0.finish() } }
    )
    let adapter = HerdrInputContextAdapter(client: client, clock: ImmediateClock()) { _ in }

    adapter.start()
    await waitUntil { requestCount.value == 1 }
    adapter.refreshNow()
    for _ in 0..<20 {
      await Task.yield()
    }

    #expect(requestCount.value == 1)
    let continuation = try #require(
      requestContinuation.withValue { value in
        defer { value = nil }
        return value
      }
    )
    continuation.resume(
      returning: HerdrPaneInfo(paneID: "w1:p1", agent: "codex", agentStatus: "working")
    )
    adapter.stop()
  }

  @Test func adapterDropsImmediateRefreshResultAfterStop() async throws {
    let paneContinuation = LockIsolated<CheckedContinuation<HerdrPaneInfo, Never>?>(nil)
    let receivedPanes = LockIsolated<[HerdrPaneInfo]>([])
    let client = HerdrInputContextClient(
      currentPane: { _ in
        await withCheckedContinuation { continuation in
          paneContinuation.setValue(continuation)
        }
      },
      events: { AsyncStream { $0.finish() } }
    )
    let adapter = HerdrInputContextAdapter(client: client, clock: ImmediateClock()) { pane in
      receivedPanes.withValue { $0.append(pane) }
    }

    adapter.start()
    await waitUntil { paneContinuation.value != nil }
    adapter.refreshNow()
    adapter.stop()

    let continuation = try #require(
      paneContinuation.withValue { value in
        defer { value = nil }
        return value
      }
    )
    continuation.resume(
      returning: HerdrPaneInfo(paneID: "w1:stale", agent: "codex", agentStatus: "working")
    )
    for _ in 0..<20 {
      await Task.yield()
    }

    #expect(receivedPanes.value.isEmpty)
  }
}

nonisolated private struct HerdrTestExchange: Sendable {
  let expectedMethod: String
  let response: String
  var expectedSubscriptionTypes: [String]? = nil
  var keepsConnectionOpen = false
}

nonisolated private final class HerdrSingleRequestTestServer: @unchecked Sendable {
  let socketPath: String

  private let exchanges: [HerdrTestExchange]
  private let lock = NSLock()
  private let completion = DispatchSemaphore(value: 0)
  private let clientDisconnect = DispatchSemaphore(value: 0)
  private var listenerFileDescriptor: Int32
  private var clientFileDescriptor: Int32 = -1
  private var isStopped = false
  private var failure: String?

  init(exchanges: [HerdrTestExchange]) throws {
    self.exchanges = exchanges
    socketPath = "/tmp/prowl-herdr-\(UUID().uuidString.prefix(8)).sock"
    listenerFileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard listenerFileDescriptor >= 0 else {
      throw HerdrTestServerError.systemCall("socket", errno)
    }

    Darwin.unlink(socketPath)
    let bindResult = withSocketAddress { address in
      withUnsafePointer(to: address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
          Darwin.bind(
            listenerFileDescriptor,
            socketAddress,
            socklen_t(MemoryLayout<sockaddr_un>.size)
          )
        }
      }
    }
    guard bindResult == 0 else {
      let errorNumber = errno
      Darwin.close(listenerFileDescriptor)
      listenerFileDescriptor = -1
      throw HerdrTestServerError.systemCall("bind", errorNumber)
    }
    guard Darwin.listen(listenerFileDescriptor, Int32(exchanges.count)) == 0 else {
      let errorNumber = errno
      Darwin.close(listenerFileDescriptor)
      listenerFileDescriptor = -1
      throw HerdrTestServerError.systemCall("listen", errorNumber)
    }
  }

  var failureDescription: String? {
    lock.withLock { failure }
  }

  func waitForClientDisconnect(timeout: DispatchTime) -> Bool {
    clientDisconnect.wait(timeout: timeout) == .success
  }

  func start() {
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      defer { completion.signal() }
      do {
        try serveExchanges()
      } catch {
        lock.withLock {
          if !isStopped {
            failure = String(describing: error)
          }
        }
      }
    }
  }

  func stop() {
    let descriptors = lock.withLock { () -> (listener: Int32, client: Int32) in
      isStopped = true
      let result = (listenerFileDescriptor, clientFileDescriptor)
      listenerFileDescriptor = -1
      return result
    }
    if descriptors.client >= 0 {
      _ = Darwin.shutdown(descriptors.client, SHUT_RDWR)
    }
    if descriptors.listener >= 0 {
      _ = Darwin.shutdown(descriptors.listener, SHUT_RDWR)
      Darwin.close(descriptors.listener)
    }
    _ = completion.wait(timeout: .now() + 2)
    Darwin.unlink(socketPath)
  }

  private func serveExchanges() throws {
    for exchange in exchanges {
      let descriptor = Darwin.accept(currentListenerFileDescriptor(), nil, nil)
      guard descriptor >= 0 else {
        throw HerdrTestServerError.systemCall("accept", errno)
      }
      lock.withLock { clientFileDescriptor = descriptor }
      defer {
        lock.withLock {
          if clientFileDescriptor == descriptor {
            clientFileDescriptor = -1
          }
        }
        Darwin.close(descriptor)
      }

      let request = try readLine(from: descriptor)
      let requestObject = try JSONSerialization.jsonObject(with: request) as? [String: Any]
      guard requestObject?["method"] as? String == exchange.expectedMethod else {
        throw HerdrTestServerError.unexpectedRequest(String(decoding: request, as: UTF8.self))
      }
      if let expectedSubscriptionTypes = exchange.expectedSubscriptionTypes {
        let params = requestObject?["params"] as? [String: Any]
        let subscriptions = params?["subscriptions"] as? [[String: Any]]
        let actualSubscriptionTypes = subscriptions?.compactMap { $0["type"] as? String }
        guard actualSubscriptionTypes == expectedSubscriptionTypes else {
          throw HerdrTestServerError.unexpectedRequest(String(decoding: request, as: UTF8.self))
        }
      }
      try writeLine(exchange.response, to: descriptor)
      if exchange.keepsConnectionOpen {
        waitForDisconnect(from: descriptor)
      }
    }
  }

  private func currentListenerFileDescriptor() -> Int32 {
    lock.withLock { listenerFileDescriptor }
  }

  private func readLine(from descriptor: Int32) throws -> Data {
    var result = Data()
    var byte: UInt8 = 0
    while result.count < 1_048_576 {
      let count = Darwin.read(descriptor, &byte, 1)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw HerdrTestServerError.systemCall("read", count < 0 ? errno : ECONNRESET)
      }
      if byte == 0x0A { return result }
      result.append(byte)
    }
    throw HerdrTestServerError.responseTooLarge
  }

  private func writeLine(_ line: String, to descriptor: Int32) throws {
    let payload = Data("\(line)\n".utf8)
    try payload.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw HerdrTestServerError.systemCall("write", errno)
        }
        offset += count
      }
    }
  }

  private func waitForDisconnect(from descriptor: Int32) {
    var byte: UInt8 = 0
    while Darwin.read(descriptor, &byte, 1) > 0 {}
    clientDisconnect.signal()
  }

  private func withSocketAddress<Result>(
    _ body: (sockaddr_un) throws -> Result
  ) rethrows -> Result {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    let maximumLength = MemoryLayout.size(ofValue: address.sun_path) - 1
    precondition(pathBytes.count <= maximumLength)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.copyBytes(from: pathBytes)
      destination[pathBytes.count] = 0
    }
    return try body(address)
  }
}

nonisolated private enum HerdrTestServerError: Error {
  case systemCall(String, Int32)
  case unexpectedRequest(String)
  case responseTooLarge
}

@MainActor
private func waitUntil(
  _ condition: @MainActor @escaping () -> Bool,
  maxIterations: Int = 500
) async {
  for _ in 0..<maxIterations {
    guard !condition() else { return }
    await Task.yield()
  }
}
