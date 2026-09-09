import Foundation
import Network
import Observation

@MainActor
@Observable
final class MirrorClient: Identifiable {
  let id = UUID()
  let address: String
  let port: UInt16
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
  @ObservationIgnored private let pairingKey: String
  @ObservationIgnored private var peer: MirrorConnection?
  @ObservationIgnored private var historyID: UUID?
  @ObservationIgnored private var historyPageGate = MirrorHistoryPageGate()
  @ObservationIgnored private var subscriptionID: UUID?
  @ObservationIgnored private var version = 1
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

  init(address: String, port: UInt16, pairingKey: String, replica: MirrorReplica) {
    self.address = address
    self.port = port
    self.pairingKey = pairingKey
    self.replica = replica
  }

  func connect() {
    guard peer == nil else { return }
    error = nil
    endReason = nil
    version = 1
    subscriptionID = nil
    isSubscribed = false
    isConnecting = true
    do {
      let peer = MirrorConnection(
        NWConnection(
          host: .init(address), port: .init(rawValue: port)!,
          using: try MirrorConnection.parameters(pairingKey: pairingKey)))
      self.peer = peer
      peer.onReady = { [weak self, weak peer] in
        guard let self, let peer, self.peer === peer else { return }
        self.isConnected = true
        peer.send(MirrorMessage(kind: .list, supportedVersions: [2, 1]))
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

  func refreshPanes() { peer?.send(MirrorMessage(kind: .list, supportedVersions: [2, 1])) }

  func subscribe(_ pane: MirrorPaneDescriptor) {
    guard selectedPane == nil, isConnected else { return }
    selectedPane = pane
    resumeIntent = .takeover
    beginSubscription()
  }

  private func beginSubscription() {
    guard let pane = selectedPane else { return }
    do {
      replica.onMessage = { [weak self] message in
        guard let self, self.isSubscribed,
          message.kind == .input || message.kind == .acknowledge,
          self.version == 1 || message.subscriptionID == self.subscriptionID
        else { return }
        self.peer?.send(message)
      }
      replica.onFailure = { [weak self] reason in self?.peer?.close(reason) }
      try replica.start()
      peer?.send(
        MirrorMessage(
          version: version, kind: .subscribe, paneID: pane.id,
          representation: version == 2 ? .terminal : nil, intent: version == 2 ? resumeIntent : nil)
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
    guard isSubscribed, supportsHistory, !isLoadingHistory else { return }
    guard refresh || historyID == nil || historyOffset > 0 else { return }
    if refresh {
      historyID = nil
      historyLines = []
      historyOffset = 0
    }
    isLoadingHistory = true
    showsHistory = true
    peer?.send(
      MirrorMessage(
        version: version, kind: .history, historyID: historyID,
        offset: historyID == nil ? nil : historyOffset, subscriptionID: subscriptionID))
  }

  private func receive(_ message: MirrorMessage) {
    switch message.kind {
    case .panes: receivePanes(message)
    case .state: break
    case .subscribed:
      guard version == 2, message.version == 2, message.paneID == selectedPane?.id,
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
        version == 1 || (subscriptionID != nil && message.subscriptionID == subscriptionID)
      else {
        peer?.close("Unexpected Host frame.")
        return
      }
      isSubscribed = true
      replica.display(message)
    case .historyPage:
      if historyID == nil { historyPageGate = MirrorHistoryPageGate() }
      guard isLoadingHistory, version == 1 || message.subscriptionID == subscriptionID,
        let id = message.historyID, let offset = message.offset,
        let lines = message.lines, lines.count <= MirrorHistory.pageSize, offset >= 0,
        historyID == nil || historyID == id,
        historyPageGate.accept(message, requiresTimestamp: version == 2)
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
    version = message.selectedVersion == 2 ? 2 : 1
    supportsHistory = version == 1 || message.capabilities?.contains("history") == true
    supportsTakeover = version == 2 && message.capabilities?.contains("takeover") == true
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
