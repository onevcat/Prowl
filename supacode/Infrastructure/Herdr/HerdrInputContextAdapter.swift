import Foundation

nonisolated internal struct HerdrInputContextClient: Sendable {
  internal let currentPane: @Sendable () async throws -> HerdrPaneInfo
  internal let events: @Sendable () -> AsyncStream<HerdrEventStreamState>

  internal init(socketClient: HerdrSocketClient = HerdrSocketClient()) {
    currentPane = {
      try await socketClient.currentPane()
    }
    events = {
      socketClient.events()
    }
  }

  internal init(
    currentPane: @escaping @Sendable () async throws -> HerdrPaneInfo,
    events: @escaping @Sendable () -> AsyncStream<HerdrEventStreamState>
  ) {
    self.currentPane = currentPane
    self.events = events
  }
}

@MainActor
internal final class HerdrInputContextAdapter {
  internal typealias PaneContextHandler = @MainActor (HerdrPaneInfo) -> Void

  private let client: HerdrInputContextClient
  private let clock: any Clock<Duration>
  private let onPaneContext: PaneContextHandler
  private let logger = SupaLogger("HerdrInputContext")
  private var lifecycleTask: Task<Void, Never>?
  private var isCompatibilityPaused = false

  internal init(
    client: HerdrInputContextClient = HerdrInputContextClient(),
    clock: any Clock<Duration> = ContinuousClock(),
    onPaneContext: @escaping PaneContextHandler
  ) {
    self.client = client
    self.clock = clock
    self.onPaneContext = onPaneContext
  }

  internal var isRunning: Bool {
    lifecycleTask != nil
  }

  internal func start() {
    guard lifecycleTask == nil, !isCompatibilityPaused else { return }
    lifecycleTask = Task { [weak self] in
      await self?.run()
    }
  }

  internal func stop() {
    lifecycleTask?.cancel()
    lifecycleTask = nil
  }

  internal func resetAfterHerdrExit() {
    stop()
    isCompatibilityPaused = false
  }

  private func run() async {
    var retryDelay = Duration.milliseconds(250)
    while !Task.isCancelled {
      do {
        try await refreshCurrentPane()
        retryDelay = .milliseconds(250)
        var shouldReconnect = false
        for await state in client.events() {
          guard !Task.isCancelled else { return }
          switch state {
          case .event:
            try? await clock.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            try await refreshCurrentPane()
          case .disconnected(let error):
            if pauseForCompatibilityFailure(error) {
              return
            }
            logger.debug("Herdr event socket disconnected: \(String(describing: error))")
            shouldReconnect = true
          }
          if shouldReconnect { break }
        }
      } catch let error as HerdrSocketError {
        if pauseForCompatibilityFailure(error) {
          return
        }
        logger.debug("Herdr input context unavailable: \(String(describing: error))")
      } catch {
        logger.debug("Herdr input context unavailable: \(error.localizedDescription)")
      }

      try? await clock.sleep(for: retryDelay)
      retryDelay = min(retryDelay * 2, .seconds(2))
    }
  }

  private func refreshCurrentPane() async throws {
    let pane = try await client.currentPane()
    guard !Task.isCancelled else { return }
    onPaneContext(pane)
  }

  private func pauseForCompatibilityFailure(_ error: HerdrSocketError) -> Bool {
    switch error {
    case .unsupportedResponseType, .unsupportedProtocol:
      logger.warning(
        "Herdr protocol is incompatible; input source integration paused: \(String(describing: error))"
      )
      isCompatibilityPaused = true
      lifecycleTask = nil
      return true
    default:
      return false
    }
  }
}
