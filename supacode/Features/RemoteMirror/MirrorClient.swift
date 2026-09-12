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
  private(set) var endReason: MirrorMessage.EndReason?
  private(set) var supportsTakeover = false
  private(set) var supportsHistory = true
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
  @ObservationIgnored private var resumeIntent: MirrorMessage.Intent = .ifFree

  var statusLabel: String {
    if isConnecting { return "Connecting…" }
    switch endReason {
    case .takenOver: return "Taken over"
    case .hostStopped: return "Host stopped"
    case .paneClosed: return "Pane closed"
    case nil: return isSubscribed ? "Connected" : "Disconnected"
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
    endReason = nil
    subscriptionID = nil
    isSubscribed = false
    isConnecting = true
    do {
      let peer = makeConnection(configuration)
      self.peer = peer
      peer.onEnrolled = { [weak self, weak peer] enrolled in
        guard let self, let peer, self.peer === peer else { return }
        self.configuration = enrolled
        self.enrolledConfiguration = enrolled
      }
      peer.onReady = { [weak self, weak peer] in
        guard let self, let peer, self.peer === peer else { return }
        if let verified = peer.verifiedConfiguration { self.configuration = verified }
        self.isConnected = true
        peer.send(.list)
      }
      peer.onMessage = { [weak self, weak peer] message in
        guard let self, let peer, self.peer === peer else { return }
        self.receive(message)
      }
      peer.onClose = { [weak self, weak peer] reason in
        guard let self, let peer, self.peer === peer else { return }
        self.peer = nil
        self.isConnected = false
        self.isConnecting = false
        self.isLoadingHistory = false
        self.isSubscribed = false
        self.subscriptionID = nil
        self.error = self.error ?? reason ?? "Connection lost. Remote status is unknown."
      }
      peer.start()
    } catch {
      isConnecting = false
      self.error = error.localizedDescription
    }
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
        self.peer?.send(message)
      }
      replica.onFailure = { [weak self] reason in self?.peer?.close(reason) }
      try replica.start()
      peer?.send(
        .subscribe(.init(paneID: pane.id, representation: .terminal, intent: resumeIntent))
      )
    } catch { peer?.close(error.localizedDescription) }
  }

  func close() {
    peer?.onClose = nil
    peer?.close()
    peer = nil
    replica.stop()
    isConnected = false
    isConnecting = false
    isLoadingHistory = false
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
    peer?.send(
      .history(
        .init(
          historyID: historyID, offset: historyID == nil ? nil : historyOffset,
          subscriptionID: subscriptionID)))
  }

  private func receive(_ message: MirrorMessage) {
    switch message.kind {
    case .panes: receivePanes(message)
    case .subscribed:
      guard message.paneID == selectedPane?.id,
        let id = message.subscriptionID
      else {
        peer?.close("Invalid subscription.")
        return
      }
      subscriptionID = id
      historyID = nil
      historyLines = []
      historyOffset = 0
      showsHistory = false
    case .ended:
      receiveEnd(message)
    case .frame:
      guard selectedPane != nil,
        subscriptionID != nil && message.subscriptionID == subscriptionID
      else {
        peer?.close("Unexpected Host frame.")
        return
      }
      isSubscribed = true
      replica.display(message)
    case .historyPage:
      if historyID == nil { historyPageGate = MirrorHistoryPageGate() }
      guard isLoadingHistory, message.subscriptionID == subscriptionID,
        let id = message.historyID, let offset = message.offset,
        let lines = message.lines, lines.count <= MirrorHistory.pageSize, offset >= 0,
        historyID == nil || historyID == id,
        historyPageGate.accept(message)
      else {
        peer?.close("Invalid history page.")
        return
      }
      historyTruncated = message.truncated ?? false
      historyID = id
      historyOffset = offset
      historyLines.insert(contentsOf: lines, at: 0)
      isLoadingHistory = false
    case .failure:
      if message.error?.hasPrefix("HISTORY_UNAVAILABLE") == true,
        message.subscriptionID == subscriptionID
      {
        isLoadingHistory = false
        error = message.error
        return
      }
      if message.error?.hasPrefix("PANE_BUSY") == true { endReason = .takenOver }
      peer?.close(message.error ?? "Host rejected the request.")
    default: peer?.close("Unexpected Host message.")
    }
  }

  private func receiveEnd(_ message: MirrorMessage) {
    guard let reason = message.reason else {
      peer?.close("Invalid Host status.")
      return
    }
    endReason = reason
    switch reason {
    case .takenOver: error = "Another device took over this pane. The last frame is retained."
    case .hostStopped: error = "Host stopped sharing. The Host program may still be running."
    case .paneClosed: error = "Host pane closed. Choose another pane from Add to Prowl."
    }
    peer?.close()
  }

  private func receivePanes(_ message: MirrorMessage) {
    panes = message.panes ?? []
    supportsHistory = message.capabilities?.contains("history") == true
    supportsTakeover = message.capabilities?.contains("takeover") == true
    isConnecting = false
    onVerifiedConnection?()
    if selectedPane != nil, !isSubscribed {
      guard panes.contains(where: { $0.id == selectedPane?.id }) else {
        endReason = .paneClosed
        error = "Host pane closed. Choose another pane from Add to Prowl."
        peer?.close()
        return
      }
      beginSubscription()
    }
  }

}
