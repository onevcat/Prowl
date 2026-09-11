import ComposableArchitecture
import Foundation
import Observation

@MainActor
@Observable
final class RemoteMirrorStore {
  let host: MirrorHost
  private(set) var clients: [MirrorClient] = []
  var selectedID: UUID?
  private(set) var credentialError: String?
  @ObservationIgnored private let runtime: GhosttyRuntime

  init(manager: WorktreeTerminalManager, runtime: GhosttyRuntime) {
    @Dependency(FeatureFlags.self) var flags
    host = MirrorHost(
      source: GhosttyMirrorPaneSource(manager: manager), enabled: flags.remoteMirror)
    self.runtime = runtime
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
    for client in clients { client.close() }
  }
}
