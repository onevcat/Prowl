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

  @Test(
    arguments: [
      "pane.focused",
      "pane.updated",
      "pane.agent_detected",
      "pane.agent_status_changed",
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

  @Test func acceptsSupportedHerdrProtocol() throws {
    let response = try JSONDecoder().decode(
      HerdrResponseEnvelope.self,
      from: Data(
        #"{"id":"clean-protocol","result":{"type":"pong","version":"0.1.0","protocol":19,"future_field":true}}"#
          .utf8
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

  @Test func currentPaneUsesASeparateConnectionAfterProtocolCheck() async throws {
    let server = try HerdrSingleRequestTestServer(
      exchanges: [
        .init(
          expectedMethod: "ping",
          response:
            #"{"id":"prowl-clean-protocol","result":{"type":"pong","version":"0.8.0","protocol":19}}"#
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
            #"{"id":"prowl-clean-protocol","result":{"type":"pong","version":"0.8.0","protocol":19}}"#
        ),
        .init(
          expectedMethod: "events.subscribe",
          response:
            #"{"id":"prowl-clean-events","result":{"type":"subscription_started"}}"#,
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
    let paneContextCount = LockIsolated(0)
    let client = HerdrInputContextClient(
      currentPane: {
        attemptCount.withValue { $0 += 1 }
        throw HerdrSocketError.unsupportedProtocol(expected: 19, actual: 20)
      },
      events: { AsyncStream { $0.finish() } }
    )
    let adapter = HerdrInputContextAdapter(client: client, clock: clock) { _ in
      paneContextCount.withValue { $0 += 1 }
    }

    adapter.start()
    await waitUntil { attemptCount.value == 1 && !adapter.isRunning }

    #expect(attemptCount.value == 1)
    #expect(!adapter.isRunning)
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
          continuation.yield(.event)
        }
      }
    )
    let adapter = HerdrInputContextAdapter(client: client, clock: ImmediateClock()) { _ in }

    adapter.start()
    await waitUntil { refreshCount.value == 2 }

    #expect(refreshCount.value == 2)
    adapter.stop()
  }
}

nonisolated private struct HerdrTestExchange: Sendable {
  let expectedMethod: String
  let response: String
  var keepsConnectionOpen = false
}

nonisolated private final class HerdrSingleRequestTestServer: @unchecked Sendable {
  let socketPath: String

  private let exchanges: [HerdrTestExchange]
  private let lock = NSLock()
  private let completion = DispatchSemaphore(value: 0)
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
  }

  private func withSocketAddress<Result>(_ body: (sockaddr_un) throws -> Result) rethrows -> Result {
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
