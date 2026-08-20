import Foundation

nonisolated internal struct HerdrInputContextClient: Sendable {
  internal let currentPane: @Sendable (Bool) async throws -> HerdrPaneInfo
  internal let events: @Sendable () -> AsyncStream<HerdrEventStreamState>

  internal init(socketClient: HerdrSocketClient = HerdrSocketClient()) {
    currentPane = { validateProtocol in
      try await socketClient.currentPane(validateProtocol: validateProtocol)
    }
    events = {
      socketClient.events()
    }
  }

  internal init(
    currentPane: @escaping @Sendable () async throws -> HerdrPaneInfo,
    events: @escaping @Sendable () -> AsyncStream<HerdrEventStreamState>
  ) {
    self.init(
      currentPane: { _ in
        try await currentPane()
      },
      events: events
    )
  }

  internal init(
    currentPane: @escaping @Sendable (Bool) async throws -> HerdrPaneInfo,
    events: @escaping @Sendable () -> AsyncStream<HerdrEventStreamState>
  ) {
    self.currentPane = { validateProtocol in
      try await currentPane(validateProtocol)
    }
    self.events = events
  }
}

@MainActor
internal final class HerdrInputContextAdapter {
  internal typealias PaneContextHandler = @MainActor (HerdrPaneInfo) -> Void
  internal typealias CompatibilityFailureHandler = @MainActor (HerdrSocketError) -> Void

  private static let pollingInterval = Duration.milliseconds(100)

  private let client: HerdrInputContextClient
  private let clock: any Clock<Duration>
  private let onCompatibilityFailure: CompatibilityFailureHandler
  private let onPaneContext: PaneContextHandler
  private let logger = SupaLogger("HerdrInputContext")
  private var lifecycleTask: Task<Void, Never>?
  private var pollingTask: Task<Void, Never>?
  private var refreshTask: Task<HerdrPaneInfo, Error>?
  private var refreshRequestID: UInt64 = 0
  private var isCompatibilityPaused = false
  private var lastPublishedPane: HerdrPaneInfo?

  internal init(
    client: HerdrInputContextClient = HerdrInputContextClient(),
    clock: any Clock<Duration> = ContinuousClock(),
    onCompatibilityFailure: @escaping CompatibilityFailureHandler = { _ in },
    onPaneContext: @escaping PaneContextHandler
  ) {
    self.client = client
    self.clock = clock
    self.onCompatibilityFailure = onCompatibilityFailure
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
    pollingTask?.cancel()
    pollingTask = nil
    refreshRequestID &+= 1
    refreshTask?.cancel()
    refreshTask = nil
    lastPublishedPane = nil
  }

  internal func resetAfterHerdrExit() {
    stop()
    isCompatibilityPaused = false
  }

  internal func refreshNow() {
    guard lifecycleTask != nil else { return }
    Task { [weak self] in
      do {
        try await self?.refreshCurrentPane(validateProtocol: false)
      } catch {
        self?.logger.debug(
          "Herdr immediate pane refresh unavailable: \(error.localizedDescription)"
        )
      }
    }
  }

  internal func reapplyLastPaneContext() {
    guard let lastPublishedPane else { return }
    onPaneContext(lastPublishedPane)
  }

  private func run() async {
    var retryDelay = Duration.milliseconds(250)
    while !Task.isCancelled {
      do {
        try await refreshCurrentPane(validateProtocol: true)
        startPolling()
        defer { stopPolling() }
        var shouldReconnect = false
        for await state in client.events() {
          guard !Task.isCancelled else { return }
          switch state {
          case .subscribed:
            retryDelay = .milliseconds(250)
            try await refreshCurrentPane(validateProtocol: false)
          case .event:
            retryDelay = .milliseconds(250)
            try await refreshCurrentPane(validateProtocol: false)
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

  private func startPolling() {
    pollingTask?.cancel()
    pollingTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await clock.sleep(for: Self.pollingInterval)
        guard !Task.isCancelled else { return }
        do {
          try await refreshCurrentPane(validateProtocol: false)
        } catch {
          logger.debug("Herdr pane polling unavailable: \(error.localizedDescription)")
        }
      }
    }
  }

  private func stopPolling() {
    pollingTask?.cancel()
    pollingTask = nil
  }

  private func refreshCurrentPane(validateProtocol: Bool) async throws {
    let task: Task<HerdrPaneInfo, Error>
    let requestID: UInt64
    if let refreshTask {
      task = refreshTask
      requestID = refreshRequestID
    } else {
      refreshRequestID &+= 1
      requestID = refreshRequestID
      let client = client
      task = Task.detached(priority: .utility) {
        try await client.currentPane(validateProtocol)
      }
      refreshTask = task
    }
    defer {
      if refreshRequestID == requestID {
        refreshTask = nil
      }
    }

    let pane = try await task.value
    guard !Task.isCancelled else { return }
    guard refreshRequestID == requestID else { return }
    if let lastPublishedPane,
      lastPublishedPane.paneID == pane.paneID,
      lastPublishedPane.inputContext == pane.inputContext
    {
      return
    }
    lastPublishedPane = pane
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
      onCompatibilityFailure(error)
      return true
    default:
      return false
    }
  }
}
