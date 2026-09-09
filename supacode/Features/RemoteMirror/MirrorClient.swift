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
  private(set) var historyLines: [String] = []
  private(set) var historyOffset = 0
  private(set) var isLoadingHistory = false
  var showsHistory = false
  let replica: MirrorReplica
  @ObservationIgnored private let pairingKey: String
  @ObservationIgnored private var peer: MirrorConnection?
  @ObservationIgnored private var historyID: UUID?

  init(address: String, port: UInt16, pairingKey: String, replica: MirrorReplica) {
    self.address = address
    self.port = port
    self.pairingKey = pairingKey
    self.replica = replica
  }

  func connect() {
    guard peer == nil else { return }
    error = nil
    isConnecting = true
    do {
      let peer = MirrorConnection(
        NWConnection(
          host: .init(address), port: .init(rawValue: port)!,
          using: try MirrorConnection.parameters(pairingKey: pairingKey)))
      self.peer = peer
      peer.onReady = { [weak self, weak peer] in
        guard let self else { return }
        self.isConnecting = false
        self.isConnected = true
        peer?.send(MirrorMessage(kind: .list))
      }
      peer.onMessage = { [weak self] in self?.receive($0) }
      peer.onClose = { [weak self] reason in
        guard let self else { return }
        self.peer = nil
        self.isConnected = false
        self.isConnecting = false
        self.isLoadingHistory = false
        self.error = reason ?? "Disconnected from Host."
        self.replica.stop()
      }
      peer.start()
    } catch {
      isConnecting = false
      self.error = error.localizedDescription
    }
  }

  func refreshPanes() { peer?.send(MirrorMessage(kind: .list)) }

  func subscribe(_ pane: MirrorPaneDescriptor) {
    guard selectedPane == nil, isConnected else { return }
    selectedPane = pane
    do {
      replica.onMessage = { [weak self] message in
        guard message.kind == .input || message.kind == .acknowledge else { return }
        self?.peer?.send(message)
      }
      replica.onFailure = { [weak self] reason in self?.peer?.close(reason) }
      try replica.start()
      peer?.send(MirrorMessage(kind: .subscribe, paneID: pane.id))
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
    historyLines = []
    historyID = nil
  }

  func loadHistory(refresh: Bool = false) {
    guard isConnected, !isLoadingHistory else { return }
    if refresh {
      historyID = nil
      historyLines = []
      historyOffset = 0
    }
    isLoadingHistory = true
    showsHistory = true
    peer?.send(MirrorMessage(kind: .history, historyID: historyID, offset: historyID == nil ? nil : historyOffset))
  }

  private func receive(_ message: MirrorMessage) {
    switch message.kind {
    case .panes: panes = message.panes ?? []
    case .frame:
      guard selectedPane != nil else {
        peer?.close("Unexpected Host frame.")
        return
      }
      replica.display(message)
    case .historyPage:
      guard isLoadingHistory, let id = message.historyID, let offset = message.offset,
        let lines = message.lines, lines.count <= MirrorHistory.pageSize, offset >= 0,
        historyID == nil || historyID == id
      else {
        peer?.close("Invalid history page.")
        return
      }
      historyID = id
      historyOffset = offset
      historyLines.insert(contentsOf: lines, at: 0)
      isLoadingHistory = false
    case .failure: peer?.close(message.error ?? "Host rejected the request.")
    default: peer?.close("Unexpected Host message.")
    }
  }
}
