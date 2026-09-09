import Foundation
import Observation

@MainActor
@Observable
final class RemoteMirrorStore {
  let host: MirrorHost
  let controlConsole: HostControlConsole
  private(set) var clients: [MirrorClient] = []
  var selectedID: UUID?
  private(set) var credentialError: String?
  @ObservationIgnored private let runtime: GhosttyRuntime

  init(manager: WorktreeTerminalManager, runtime: GhosttyRuntime, profiles: [AgentProfile] = []) {
    host = MirrorHost(source: GhosttyMirrorPaneSource(manager: manager))
    controlConsole = HostControlConsole(manager: manager, profiles: profiles)
    self.runtime = runtime
    host.onStarted = { [weak controlConsole] in controlConsole?.start() }
    host.onStopped = { [weak controlConsole] in controlConsole?.cancelPreparation() }
  }

  var selected: MirrorClient? { clients.first { $0.id == selectedID } }

  func makeClient(address: String, port: UInt16, pairingKey: String) -> MirrorClient {
    let client = MirrorClient(
      address: address, port: port, pairingKey: pairingKey, replica: MirrorReplica(runtime: runtime)
    )
    client.onVerifiedConnection = { [weak self] in
      do {
        try MirrorSavedConnection(address: address, port: port, pairingKey: pairingKey).save()
        self?.credentialError = nil
      } catch { self?.credentialError = error.localizedDescription }
    }
    return client
  }

  func savedConnection() -> MirrorSavedConnection? {
    do { return try MirrorSavedConnection.load() } catch {
      credentialError = error.localizedDescription
      return nil
    }
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
    controlConsole.stop()
    for client in clients { client.close() }
  }
}
