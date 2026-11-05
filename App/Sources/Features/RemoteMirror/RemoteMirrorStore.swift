import ComposableArchitecture
import Foundation
import Observation

@MainActor
@Observable
final class RemoteMirrorStore {
  let host: MirrorHost
  private(set) var clients: [MirrorClient] = []
  var selectedID: UUID?
  let knownHosts = MirrorKnownHostStore()
  @ObservationIgnored private let runtime: GhosttyRuntime
  @ObservationIgnored private let paneSource: GhosttyMirrorPaneSource

  init(manager: WorktreeTerminalManager, runtime: GhosttyRuntime) {
    @Dependency(FeatureFlags.self) var flags
    paneSource = GhosttyMirrorPaneSource(manager: manager)
    host = MirrorHost(source: paneSource, enabled: flags.remoteMirror)
    self.runtime = runtime
  }

  /// The sidebar's project names, colors and order for the pane roster (docs-ai 089).
  func updateRosterDecorations(_ decorations: MirrorRosterDecorations) {
    paneSource.decorations = decorations
  }

  var selected: MirrorClient? { clients.first { $0.id == selectedID } }

  func makeClient(address: String, port: UInt16, pairingKey: String) -> MirrorClient {
    let client = MirrorClient(
      configuration: .init(address: address, port: port, pairingKey: pairingKey),
      replica: MirrorReplica(runtime: runtime)
    )
    return client
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
