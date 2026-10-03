import Foundation
import Network
import Observation

@MainActor
@Observable
final class MirrorClient: Identifiable {
  let id = UUID()
  let address: String
  let port: UInt16
  private(set) var enrolledConfiguration: MirrorSavedConnection?
  private(set) var panes: [MirrorPaneDescriptor] = []
  private(set) var selectedPane: MirrorPaneDescriptor?
  private(set) var isConnected = false
  private(set) var isConnecting = false
  private(set) var error: String?
  /// Why the last attempt ended before authentication, when the transport could tell.
  private(set) var failure: MirrorConnectionFailure?
  private(set) var verifiedHostID: UUID?
  private(set) var endReason: MirrorMessage.EndReason?
  private(set) var supportsTakeover = false
  private(set) var supportsProfileLaunch = false
  private(set) var supportsShellLaunch = false
  private(set) var supportsHistory = true
  private(set) var supportsRemoteScroll = false
  private(set) var supportsScrollState = false
  private(set) var scrollBoundsState = MirrorScrollBoundsState()
  private(set) var supportsStyledScrollback = false
  private(set) var supportsViewportText = false
  private(set) var viewportState = MirrorViewportState()
  let scrollState = MirrorScrollState()
  private(set) var historyTruncated = false
  private(set) var isSubscribed = false
  var onVerifiedConnection: (() -> Void)?
  private(set) var historyLines: [String] = []
  private(set) var historyOffset = 0
  private(set) var isLoadingHistory = false
  var showsHistory = false
  let replica: MirrorReplica
  @ObservationIgnored private var configuration: MirrorSavedConnection
  @ObservationIgnored private let makeConnection: (MirrorSavedConnection) -> MirrorRemoteConnection
  @ObservationIgnored private var peer: MirrorRemoteConnection?
  @ObservationIgnored private var historyID: UUID?
  @ObservationIgnored private var historyPageGate = MirrorHistoryPageGate()
  @ObservationIgnored private var subscriptionID: UUID?
  @ObservationIgnored private lazy var commands = MirrorCommandChannel { [weak self] in self?.peer?.send($0) }
  @ObservationIgnored private var resumeIntent: MirrorMessage.Intent = .ifFree

  var statusLabel: String {
    if isConnecting { return String(localized: "Connecting…") }
    switch endReason {
    case .takenOver: return String(localized: "Taken over")
    case .hostStopped: return String(localized: "Host stopped")
    case .paneClosed: return String(localized: "Pane closed")
    case nil:
      if isSubscribed { return String(localized: "Connected") }
      return String(localized: "Disconnected")
    }
  }

  func retry(takeover: Bool = false) {
    guard peer == nil, !isConnecting, selectedPane != nil else { return }
    resumeIntent = takeover ? .takeover : .ifFree
    connect()
  }

  init(
    configuration: MirrorSavedConnection, replica: MirrorReplica,
    makeConnection: @escaping (MirrorSavedConnection) -> MirrorRemoteConnection = {
      MirrorRemoteConnection(configuration: $0)
    }
  ) {
    self.address = configuration.address
    self.port = configuration.port
    self.configuration = configuration
    self.replica = replica
    self.makeConnection = makeConnection
  }

  func connect() {
    guard peer == nil else { return }
    error = nil
    failure = nil
    endReason = nil
    subscriptionID = nil
    scrollState.reset()
    supportsRemoteScroll = false
    supportsViewportText = false
    supportsScrollState = false
    viewportState = MirrorViewportState()
    scrollBoundsState = MirrorScrollBoundsState()
    isSubscribed = false
    isConnecting = true
    let peer = makeConnection(configuration)
    self.peer = peer
    peer.onEnrolled = { [weak self, weak peer] enrolled in
      guard let self, let peer, self.peer === peer else { return }
      self.configuration = enrolled
      self.enrolledConfiguration = enrolled
    }
    peer.onReady = { [weak self, weak peer] in
      guard let self, let peer, self.peer === peer else { return }
      if let verified = peer.verifiedConfiguration {
        self.configuration = verified
        self.verifiedHostID = verified.credential?.hostID
      }
      self.isConnected = true
      peer.send(.list)
    }
    peer.onMessage = { [weak self, weak peer] message in
      guard let self, let peer, self.peer === peer else { return }
      self.receive(message)
    }
    peer.onClose = { [weak self, weak peer] reason in
      guard let self, let peer, self.peer === peer else { return }
      self.commands.disconnect()
      self.peer = nil
      self.isConnected = false
      self.isConnecting = false
      self.isLoadingHistory = false
      self.scrollState.cancel()
      self.isSubscribed = false
      self.subscriptionID = nil
      self.failure = peer.failure
      self.error = self.error ?? reason ?? String(localized: "Connection lost. Remote status is unknown.")
    }
    peer.start()
  }

  func command(_ command: MirrorCommandRequest.Command) async throws -> MirrorJSON {
    guard isConnected, !isConnecting, selectedPane == nil, peer != nil else {
      throw MirrorCommandChannel.Failure.unavailable
    }
    return try await commands.execute(command)
  }

  func refreshPanes() { peer?.send(.list) }

  func subscribe(_ pane: MirrorPaneDescriptor) {
    guard selectedPane == nil, isConnected else { return }
    selectedPane = pane
    resumeIntent = pane.busy ? .takeover : .ifFree
    beginSubscription()
  }

  private func beginSubscription() {
    guard let pane = selectedPane else { return }
    do {
      replica.onMessage = { [weak self] message in
        guard let self, self.isSubscribed,
          message.kind == .input || message.kind == .acknowledge,
          message.subscriptionID == self.subscriptionID
        else { return }
        if message.kind == .acknowledge, let sequence = message.sequence {
          if self.supportsViewportText {
            do { try self.viewportState.didPresent(sequence: sequence) } catch {
              self.peer?.close(String(localized: "Invalid Host viewport frame."))
              return
            }
          }
          if self.supportsScrollState {
            do { try self.scrollBoundsState.didPresent(sequence: sequence) } catch {
              self.peer?.close(String(localized: "Invalid Host scroll state."))
              return
            }
          }
          self.scrollState.didPresent(sequence: sequence)
        }
        self.peer?.send(message)
      }
      replica.onFailure = { [weak self] reason in self?.peer?.close(reason) }
      try replica.start()
      peer?.send(
        .subscribe(
          .init(
            paneID: pane.id, representation: .terminal, intent: resumeIntent,
            includeViewportText: supportsViewportText ? true : nil,
            includeScrollState: supportsScrollState ? true : nil,
            includeStyledScrollback: supportsStyledScrollback ? true : nil))
      )
    } catch { peer?.close(error.localizedDescription) }
  }

  func close() {
    commands.disconnect()
    peer?.onClose = nil
    peer?.close()
    peer = nil
    replica.stop()
    isConnected = false
    isConnecting = false
    isLoadingHistory = false
    scrollState.reset()
    viewportState = MirrorViewportState()
    scrollBoundsState = MirrorScrollBoundsState()
    isSubscribed = false
    subscriptionID = nil
    historyLines = []
    historyID = nil
  }

  func loadHistory(refresh: Bool = false) {
    guard isSubscribed, supportsHistory, !isLoadingHistory, let subscriptionID else { return }
    guard refresh || historyID == nil || historyOffset > 0 else { return }
    if refresh {
      historyID = nil
      historyLines = []
      historyOffset = 0
    }
    isLoadingHistory = true
    showsHistory = true
    scrollState.cancel()
    peer?.send(
      .history(
        .init(
          historyID: historyID, offset: historyID == nil ? nil : historyOffset,
          subscriptionID: subscriptionID)))
  }

  func canScroll(_ direction: MirrorMessage.ScrollDirection) -> Bool {
    isSubscribed && supportsRemoteScroll && !showsHistory && !scrollState.isLoading
      && scrollBoundsState.canScroll(direction)
  }

  func scroll(_ direction: MirrorMessage.ScrollDirection) {
    guard canScroll(direction), let subscriptionID, let requestID = scrollState.begin() else { return }
    peer?.send(.scroll(.init(requestID: requestID, direction: direction, subscriptionID: subscriptionID)))
  }

  private func receive(_ message: MirrorMessage) {
    switch message.kind {
    case .panes: receivePanes(message)
    case .commandResult:
      guard let response = message.commandResponse else {
        peer?.close(String(localized: "Invalid command response."))
        return
      }
      commands.receive(response)
    case .subscribed:
      guard message.paneID == selectedPane?.id,
        let id = message.subscriptionID
      else {
        peer?.close(String(localized: "Invalid subscription."))
        return
      }
      subscriptionID = id
      scrollState.reset()
      viewportState = MirrorViewportState()
      scrollBoundsState = MirrorScrollBoundsState()
      historyID = nil
      historyLines = []
      historyOffset = 0
      showsHistory = false
    case .ended:
      receiveEnd(message)
    case .frame:
      receiveFrame(message)
    case .viewport:
      receiveViewport(message)
    case .scrollState:
      receiveScrollBounds(message)
    case .historyPage:
      if historyID == nil { historyPageGate = MirrorHistoryPageGate() }
      guard isLoadingHistory, message.subscriptionID == subscriptionID,
        let id = message.historyID, let offset = message.offset,
        let lines = message.lines, lines.count <= MirrorHistory.pageSize, offset >= 0,
        historyID == nil || historyID == id,
        historyPageGate.accept(message)
      else {
        peer?.close(String(localized: "Invalid history page."))
        return
      }
      historyTruncated = message.truncated ?? false
      historyID = id
      historyOffset = offset
      historyLines.insert(contentsOf: lines, at: 0)
      isLoadingHistory = false
    case .scrollResult:
      receiveScrollResult(message)
    case .failure:
      receiveFailure(message)
    default: peer?.close(String(localized: "Unexpected Host message."))
    }
  }

  private func receiveFrame(_ message: MirrorMessage) {
    guard selectedPane != nil, subscriptionID != nil && message.subscriptionID == subscriptionID else {
      peer?.close(String(localized: "Unexpected Host frame."))
      return
    }
    if supportsViewportText {
      do {
        guard let sequence = message.sequence else { throw MirrorProtocolError.invalidMessage }
        try viewportState.receiveFrame(sequence: sequence)
      } catch {
        peer?.close(String(localized: "Invalid Host viewport frame."))
        return
      }
    }
    if supportsScrollState {
      do {
        guard let sequence = message.sequence else { throw MirrorProtocolError.invalidMessage }
        try scrollBoundsState.receiveFrame(sequence: sequence)
      } catch {
        peer?.close(String(localized: "Invalid Host scroll state."))
        return
      }
    }
    isSubscribed = true
    replica.display(
      message, styledScrollback: viewportState.pendingStyledScrollback,
      viewportText: viewportState.pendingText)
  }

  private func receiveViewport(_ message: MirrorMessage) {
    guard supportsViewportText, subscriptionID != nil, message.subscriptionID == subscriptionID,
      case .viewport(let payload) = message
    else {
      peer?.close(String(localized: "Unexpected Host viewport."))
      return
    }
    do { try viewportState.stage(payload) } catch {
      peer?.close(String(localized: "Invalid Host viewport frame."))
    }
  }

  private func receiveScrollBounds(_ message: MirrorMessage) {
    guard supportsScrollState, subscriptionID != nil, message.subscriptionID == subscriptionID,
      case .scrollState(let payload) = message
    else {
      peer?.close(String(localized: "Unexpected Host scroll state."))
      return
    }
    do { try scrollBoundsState.stage(payload) } catch {
      peer?.close(String(localized: "Invalid Host scroll state."))
    }
  }

  private func receiveScrollResult(_ message: MirrorMessage) {
    guard message.subscriptionID == subscriptionID,
      let requestID = message.scrollRequestID, let sequence = message.sequence
    else {
      peer?.close(String(localized: "Invalid scroll result."))
      return
    }
    scrollState.receiveResult(requestID: requestID, sequence: sequence)
  }

  private func receiveFailure(_ message: MirrorMessage) {
    if message.error?.hasPrefix("SCROLL_") == true, message.subscriptionID == subscriptionID {
      if let requestID = message.scrollRequestID, requestID == scrollState.requestID {
        scrollState.fail(message.error ?? String(localized: "Host could not scroll."))
      }
      return
    }
    if message.error?.hasPrefix("HISTORY_UNAVAILABLE") == true,
      message.subscriptionID == subscriptionID
    {
      isLoadingHistory = false
      error = message.error
      return
    }
    if message.error?.hasPrefix("PANE_BUSY") == true { endReason = .takenOver }
    peer?.close(message.error ?? String(localized: "Host rejected the request."))
  }

  private func receiveEnd(_ message: MirrorMessage) {
    guard let reason = message.reason else {
      peer?.close(String(localized: "Invalid Host status."))
      return
    }
    endReason = reason
    switch reason {
    case .takenOver:
      error = String(localized: "Another device took over this pane. The last frame is retained.")
    case .hostStopped:
      error = String(localized: "Host stopped sharing. The Host program may still be running.")
    case .paneClosed:
      error = String(localized: "Host pane closed. Choose another pane from Add to Prowl.")
    }
    peer?.close()
  }

  private func receivePanes(_ message: MirrorMessage) {
    panes = message.panes ?? []
    supportsProfileLaunch = message.capabilities?.contains("launch-profile") == true
    supportsShellLaunch = message.capabilities?.contains("launch-shell") == true
    supportsHistory = message.capabilities?.contains("history") == true
    supportsRemoteScroll = message.capabilities?.contains("remote-scroll") == true
    supportsScrollState = message.capabilities?.contains("scroll-state-v1") == true
    supportsViewportText = message.capabilities?.contains("viewport-text-v1") == true
    supportsStyledScrollback = message.capabilities?.contains("styled-scrollback-v1") == true
    supportsTakeover = message.capabilities?.contains("takeover") == true
    isConnecting = false
    onVerifiedConnection?()
    if selectedPane != nil, !isSubscribed {
      guard panes.contains(where: { $0.id == selectedPane?.id }) else {
        endReason = .paneClosed
        error = String(localized: "Host pane closed. Choose another pane from Add to Prowl.")
        peer?.close()
        return
      }
      beginSubscription()
    }
  }

}
