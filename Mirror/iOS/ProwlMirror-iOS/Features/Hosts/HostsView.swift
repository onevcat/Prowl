import SwiftUI

nonisolated struct MirrorPaneRoute: Hashable {
  let host: MirrorHostRecord
  let pane: MirrorPaneDescriptor
}

extension MirrorPaneDescriptor: Hashable {
  nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The paired Hosts. Adding one pairs with a code or a QR; a row opens its panes.
struct HostsView: View {
  @Bindable var store: MirrorHostStore
  @Environment(MirrorHostSessions.self) private var sessions
  @State private var path = NavigationPath()
  @State private var showsAdd = false
  @State private var renaming: MirrorHostRecord?
  @State private var alias = ""

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if store.hosts.isEmpty {
          ContentUnavailableView {
            Label("No Hosts", systemImage: "desktopcomputer")
          } description: {
            Text("Pair with a Mac running Prowl to see its agents here.")
          } actions: {
            Button("Add Host") { showsAdd = true }.buttonStyle(.borderedProminent)
          }
        } else {
          List {
            ForEach(store.hosts) { host in
              NavigationLink(value: host) { HostRow(host: host, session: sessions.existing(for: host)) }
                .accessibilityIdentifier("host-\(host.endpoint)")
                .swipeActions(edge: .trailing) {
                  Button("Forget", systemImage: "trash", role: .destructive) { forget(host) }
                  Button("Rename", systemImage: "pencil") { startRenaming(host) }.tint(.indigo)
                }
                .contextMenu {
                  Button("Rename…", systemImage: "pencil") { startRenaming(host) }
                  Button("Forget", systemImage: "trash", role: .destructive) { forget(host) }
                }
            }
          }
        }
      }
      .navigationTitle("Hosts")
      .toolbar {
        Button("Add Host", systemImage: "plus") { showsAdd = true }
          .accessibilityIdentifier("add-host")
          .help("Pair with a Mac running Prowl")
      }
      .navigationDestination(for: MirrorHostRecord.self) { host in
        PanesView(host: host, path: $path)
      }
      .navigationDestination(for: MirrorPaneRoute.self) { route in
        PaneView(route: route, session: sessions.makePaneSession(route.host))
      }
      .sheet(isPresented: $showsAdd) {
        AddHostView(store: store) { host in
          showsAdd = false
          path.append(host)
        }
      }
      .alert("Rename Host", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
        TextField("Name", text: $alias)
        Button("Save") {
          if let renaming { store.rename(renaming.id, alias: alias) }
          renaming = nil
        }
        Button("Cancel", role: .cancel) { renaming = nil }
      } message: {
        Text("Shown on this device only.")
      }
    }
  }

  private func startRenaming(_ host: MirrorHostRecord) {
    alias = host.alias ?? ""
    renaming = host
  }

  private func forget(_ host: MirrorHostRecord) {
    sessions.forget(host.id)
    store.remove(host.id)
  }
}

private struct HostRow: View {
  let host: MirrorHostRecord
  let session: MirrorHostSession?

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "desktopcomputer")
        .font(.title2)
        .foregroundStyle(.tint)
        .frame(width: 32)
      VStack(alignment: .leading, spacing: 3) {
        Text(host.displayName).font(.headline)
        Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      if let session {
        Circle().fill(color(for: session.status)).frame(width: 9, height: 9)
          .accessibilityLabel(session.status.label)
      }
    }
    .padding(.vertical, 4)
  }

  private var caption: String {
    var parts = [host.endpoint]
    if let session, session.status == .ready {
      parts.append(String(localized: "\(session.panes.count) panes"))
    } else if let last = host.lastConnectedAt {
      parts.append(String(localized: "Last connected \(last.formatted(.relative(presentation: .named)))"))
    }
    return parts.joined(separator: " · ")
  }

  private func color(for status: MirrorHostSession.Status) -> Color {
    switch status {
    case .ready: .green
    case .connecting: .yellow
    case .failed: .red
    case .idle: .secondary
    }
  }
}

/// Pairs with a Host by QR or by address, port and code, then saves it.
struct AddHostView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var store: MirrorHostStore
  let onAdded: (MirrorHostRecord) -> Void
  @State private var address = ""
  @State private var port = "7880"
  @State private var code = ""
  @State private var error: String?
  @State private var session: MirrorHostSession?
  @State private var showsScanner = false

  private var isConnecting: Bool { session?.status == .connecting }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Button {
            showsScanner = true
          } label: {
            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
          }
          .disabled(isConnecting)
          .accessibilityIdentifier("scan-pairing-qr")
        } footer: {
          Text("On the Mac, open Remote Mirror → Add a Device.")
        }
        Section("Host") {
          TextField("Address", text: $address)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            .accessibilityIdentifier("host-address")
          TextField("Port", text: $port).keyboardType(.numberPad)
          MirrorPairingCodeField(key: $code)
        }
        if let error = error ?? failure {
          Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        Section {
          Button {
            connect()
          } label: {
            HStack {
              Text(isConnecting ? "Connecting…" : "Connect")
              if isConnecting {
                Spacer()
                ProgressView()
              }
            }
          }
          .disabled(isConnecting || address.trimmingCharacters(in: .whitespaces).isEmpty)
          .accessibilityIdentifier("connect-host")
        }
      }
      .navigationTitle("Add Host")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("Cancel") { dismiss() } }
      .sheet(isPresented: $showsScanner) {
        MirrorPairingScanner { text in
          showsScanner = false
          do {
            let payload = try MirrorPairingPayload.parse(text)
            address = payload.address
            port = String(payload.port)
            code = payload.code
            connect()
          } catch { self.error = error.localizedDescription }
        }
      }
      .onDisappear { session?.stop() }
    }
  }

  private var failure: String? {
    if case .failed(let reason) = session?.status { return reason }
    return nil
  }

  private func connect() {
    let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let number = UInt16(port), number > 0, !host.isEmpty else {
      error = String(localized: "Enter the Host address and a port between 1 and 65535.")
      return
    }
    let secret = code.trimmingCharacters(in: .whitespacesAndNewlines)
    do { if !secret.isEmpty { _ = try MirrorPairingCode.normalized(secret) } } catch {
      self.error = error.localizedDescription
      return
    }
    error = nil
    session?.stop()
    let pairing = MirrorHostSession(configuration: .init(address: host, port: number, pairingKey: secret))
    pairing.onVerified = { configuration in
      let record = store.upsert(address: host, port: number, hostID: configuration.credential?.hostID)
      pairing.stop()
      onAdded(record)
    }
    session = pairing
    pairing.start()
  }
}
