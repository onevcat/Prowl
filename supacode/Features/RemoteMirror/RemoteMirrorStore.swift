import Foundation
import Observation

@MainActor
@Observable
final class RemoteMirrorStore {
  let host: MirrorHost
  private(set) var clients: [MirrorClient] = []
  var selectedID: UUID?
  @ObservationIgnored private let runtime: GhosttyRuntime

  init(manager: WorktreeTerminalManager, runtime: GhosttyRuntime) {
    host = MirrorHost(source: GhosttyMirrorPaneSource(manager: manager))
    self.runtime = runtime
  }

  var selected: MirrorClient? { clients.first { $0.id == selectedID } }

  func makeClient(address: String, port: UInt16, pairingKey: String) -> MirrorClient {
    MirrorClient(address: address, port: port, pairingKey: pairingKey, replica: MirrorReplica(runtime: runtime))
  }

  func add(_ client: MirrorClient, pane: MirrorPaneDescriptor) {
    clients.append(client)
    selectedID = client.id
    client.subscribe(pane)
  }

  func remove(_ client: MirrorClient) {
    client.close()
    clients.removeAll { $0.id == client.id }
    if selectedID == client.id { selectedID = nil }
  }

  func stop() {
    host.stop()
    for client in clients { client.close() }
  }
}
