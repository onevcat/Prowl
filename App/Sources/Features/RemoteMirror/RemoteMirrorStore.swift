import Combine
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
  @ObservationIgnored @Shared(.settingsFile) private var settingsFile
  @ObservationIgnored private var settingsObservation: AnyCancellable?

  /// Opens Settings on the Remote Mirror section; the app sets it.
  @ObservationIgnored var openSettings: (() -> Void)?

  /// Brings the main window forward, because a mirror shows only there; the app sets it.
  @ObservationIgnored var showSelectedMirror: (() -> Void)?

  /// The alpha switch in Settings (docs-ai 091). The Mirror UI and the listener follow it.
  var isEnabled: Bool { settingsFile.global.remoteMirrorEnabled }

  init(manager: WorktreeTerminalManager, runtime: GhosttyRuntime) {
    paneSource = GhosttyMirrorPaneSource(manager: manager)
    // The autoclosure keeps the shared reference, so the Host reads the current value.
    let settings = Shared(.settingsFile)
    host = MirrorHost(source: paneSource, enabled: settings.wrappedValue.global.remoteMirrorEnabled)
    self.runtime = runtime
    settingsObservation = $settingsFile.publisher
      .map(\.global.remoteMirrorEnabled)
      .removeDuplicates()
      .sink { [weak self] enabled in
        // The publisher can emit off the main actor.
        Task { @MainActor in
          guard let self, !enabled else { return }
          self.disconnectAll()
        }
      }
  }

  /// Starts the listener at launch when the user asked for it in Settings.
  func startHostOnLaunchIfNeeded() {
    guard isEnabled, settingsFile.global.remoteMirrorStartsHostOnLaunch else { return }
    host.start()
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
    // The connection sheet lives in Settings; the mirror shows in the main window.
    showSelectedMirror?()
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

  /// Stops the listener and closes every outgoing mirror; hidden UI leaves no connection.
  private func disconnectAll() {
    guard !isEnabled else { return }
    host.stop()
    for client in clients { client.close() }
    clients.removeAll()
    selectedID = nil
  }
}
