import SwiftUI

nonisolated struct MirrorPaneRoute: Hashable {
  let host: MirrorHostRecord
  let pane: MirrorPaneDescriptor
  /// The pane was just launched from this device; its agent is not detected yet.
  var launched = false
}

extension MirrorPaneDescriptor: Hashable {
  nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The paired Hosts, opened from the Agents title menu (docs-ai 089): pick the Host to show,
/// rename or forget one, or pair another.
struct HostsManagerView: View {
  @Bindable var store: MirrorHostStore
  let onAddHost: () -> Void
  @Environment(MirrorHostSessions.self) private var sessions
  @Environment(\.dismiss) private var dismiss
  @State private var renaming: MirrorHostRecord?
  @State private var alias = ""

  var body: some View {
    NavigationStack {
      List {
        ForEach(store.hosts) { host in
          Button {
            store.select(host.id)
            dismiss()
          } label: {
            HostRow(host: host, session: sessions.existing(for: host), selected: host.id == store.selectedHost?.id)
          }
          .buttonStyle(.plain)
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
      .navigationTitle("Hosts")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close", systemImage: "xmark") { dismiss() }
            .help("Close the Host list")
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Add Host", systemImage: "plus") {
            dismiss()
            onAddHost()
          }
          .accessibilityIdentifier("add-host")
          .help("Pair with a Mac running Prowl")
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
    if store.hosts.isEmpty { dismiss() }
  }
}

private struct HostRow: View {
  let host: MirrorHostRecord
  let session: MirrorHostSession?
  let selected: Bool

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "macbook")
        .font(.title2)
        .foregroundStyle(.tint)
        .frame(width: 34)
      VStack(alignment: .leading, spacing: 3) {
        Text(host.displayName).font(.headline)
        Text(caption).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      if case .failed? = session?.status {
        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
          .accessibilityLabel(session?.status.label ?? "")
      } else if session?.status == .ready {
        Circle().fill(.green).frame(width: 8, height: 8).accessibilityLabel(String(localized: "Connected"))
      }
      if selected {
        Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
          .accessibilityLabel(String(localized: "Shown"))
      }
    }
    .padding(.vertical, 4)
    .contentShape(.rect)
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
