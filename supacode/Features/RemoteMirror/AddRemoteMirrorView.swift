import SwiftUI

struct AddRemoteMirrorView: View {
  @Environment(RemoteMirrorStore.self) private var mirrors
  let dismiss: () -> Void
  var savedHost: MirrorKnownHost?
  @State private var address = ""
  @State private var port = "7880"
  @State private var pairingCode = ""
  @State private var client: MirrorClient?
  @State private var error: String?
  @State private var added = false
  @State private var restored = false
  @State private var requiresNewCode = false
  @State private var showsNewPane = false
  @State private var launchModel: MirrorLaunchModel?
  @State private var launchTask: Task<Void, Never>?
  @FocusState private var codeFocused: Bool

  private var isConnecting: Bool { client?.isConnecting == true }

  private var knownHost: MirrorKnownHost? {
    guard let endpoint = try? MirrorEndpointInput.endpoint(address: address, port: port) else { return nil }
    return mirrors.knownHosts.host(address: endpoint.address, port: endpoint.port)
  }

  /// A saved credential is used silently; the code field appears only when one is missing or rejected.
  private var needsPairingCode: Bool { requiresNewCode || knownHost == nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Connect to Host").font(.title2.bold())
      if let client, client.isConnected {
        if showsNewPane, let launchModel {
          MirrorNewPaneView(model: launchModel)
        } else {
          panePicker(client)
        }
      } else {
        form
      }
      HStack {
        if let client, client.isConnected {
          if showsNewPane {
            Button("Back") {
              showsNewPane = false
              client.refreshPanes()
            }
            .disabled(launchModel?.isCreating == true)
            .help("Return to the Host pane list")
            Button("Refresh", systemImage: "arrow.clockwise") {
              launchTask = Task { await launchModel?.load() }
            }
            .labelStyle(.iconOnly)
            .disabled(
              launchModel?.isLoading == true || launchModel?.isCreating == true
                || launchModel?.creationUncertain == true
            )
            .help("Reload worktrees and Agent Profiles from Host")
          } else {
            Button("Refresh Panes") { client.refreshPanes() }
              .help("Reload the list of panes on this Host")
            if client.supportsProfileLaunch || client.supportsShellLaunch {
              Button("New Pane…", systemImage: "plus") {
                if launchModel == nil {
                  launchModel = MirrorLaunchModel(
                    supportsShell: client.supportsShellLaunch, supportsProfiles: client.supportsProfileLaunch,
                    execute: client.command)
                }
                showsNewPane = true
              }
              .help("Create a Shell or Agent Profile pane in a Host worktree")
            }
          }
        }
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
          .disabled(launchModel?.isCreating == true)
        if showsNewPane, let launchModel, let client, client.isConnected {
          Button(launchModel.isCreating ? "Creating…" : "Create and Mirror") {
            launchTask = Task {
              if let pane = await launchModel.create() {
                add(client, pane: pane)
              }
            }
          }
          .disabled(!launchModel.canCreate)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .help("Create a background tab on Host and open its mirror")
        }
        if client?.isConnected != true {
          Button(isConnecting ? "Connecting…" : "Connect") { connect() }
            .disabled(isConnecting)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(24).frame(width: 420)
    .onAppear {
      guard !restored else { return }
      restored = true
      if let saved = savedHost {
        address = saved.address
        port = String(saved.port)
        connect()
      }
    }
    .onChange(of: client?.enrolledConfiguration) { _, enrolled in
      guard let enrolled else { return }
      pairingCode = ""
      requiresNewCode = false
      mirrors.knownHosts.recordEnrollment(enrolled)
    }
    .onChange(of: client?.isConnected) { _, connected in
      guard connected == true, let client else { return }
      mirrors.knownHosts.recordConnection(address: client.address, port: client.port, hostID: client.verifiedHostID)
    }
    .onChange(of: client?.failure) { _, failure in
      guard case .handshakeRejected = failure, pairingCode.isEmpty else { return }
      requiresNewCode = true
      codeFocused = true
    }
    .interactiveDismissDisabled(launchModel?.isCreating == true)
    .onDisappear {
      launchTask?.cancel()
      if !added { client?.close() }
    }
    .accessibilityIdentifier("add-remote-mirror-panel")
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 16) {
      // Sheets propose no height; without fixedSize multi-line text collapses to one truncated line.
      Text("Enter the address shown on Host under Remote Mirror → Add a Device.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Form {
        TextField("Address", text: $address, prompt: Text("IP address"))
          .accessibilityIdentifier("remote-mirror-address")
        TextField("Port", text: $port, prompt: Text("7880"))
      }
      .disabled(isConnecting)
      if needsPairingCode {
        VStack(spacing: 6) {
          TextField("Pairing Code", text: $pairingCode, prompt: Text("XXXX-XXXX"))
            .labelsHidden()
            .font(.title.monospaced())
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 220)
            .focused($codeFocused)
            .disabled(isConnecting)
            .onChange(of: pairingCode) { _, next in
              let formatted = MirrorPairingCode.formatted(next)
              if formatted != next { pairingCode = formatted }
            }
            .accessibilityIdentifier("remote-mirror-pairing-code")
          Text("The eight-character code shown on Host under Add a Device.\nIt expires after 60 seconds.")
            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
      } else if let knownHost {
        Label("Already paired with \(knownHost.displayName). No code is needed.", systemImage: "checkmark.seal")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let message = client?.error ?? error {
        Text(message).foregroundStyle(.red).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func panePicker(_ client: MirrorClient) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Connected to \(hostLabel(client))").font(.headline).lineLimit(1)
        Text("Select a pane to mirror.").foregroundStyle(.secondary)
      }
      if client.panes.isEmpty { Text("No open panes on this Host.") }
      ScrollView {
        VStack(spacing: 8) {
          ForEach(client.panes) { pane in
            Button {
              add(client, pane: pane)
            } label: {
              HStack {
                VStack(alignment: .leading) {
                  Text(pane.projectName ?? pane.title).font(.headline).lineLimit(1)
                  Text(pane.subtitle ?? pane.directory).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer()
                Text(pane.busy ? (client.supportsTakeover ? "Take Over" : "In use") : "Mirror")
              }
              .padding(10).frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .help(pane.title + "\n" + pane.directory)
            .disabled(pane.busy && !client.supportsTakeover)
          }
        }
      }
      .frame(height: min(280, CGFloat(max(1, client.panes.count)) * 76))
    }
  }

  private func hostLabel(_ client: MirrorClient) -> String {
    mirrors.knownHosts.host(address: client.address, port: client.port)?.displayName
      ?? MirrorKnownHost.endpointID(address: client.address, port: client.port)
  }

  private func add(_ client: MirrorClient, pane: MirrorPaneDescriptor) {
    added = true
    mirrors.add(client, pane: pane)
    dismiss()
  }

  private func connect() {
    do {
      let endpoint = try MirrorEndpointInput.endpoint(address: address, port: port)
      let code = try MirrorEndpointInput.pairingCode(pairingCode, required: needsPairingCode)
      launchTask?.cancel()
      launchModel = nil
      showsNewPane = false
      client?.close()
      let connection = mirrors.makeClient(address: endpoint.address, port: endpoint.port, pairingKey: code)
      client = connection
      error = nil
      connection.connect()
    } catch {
      self.error = error.message
    }
  }
}
