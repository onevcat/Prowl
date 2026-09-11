import Network
import SwiftUI

struct AddRemoteMirrorView: View {
  @Environment(RemoteMirrorStore.self) private var mirrors
  let dismiss: () -> Void
  let back: () -> Void
  @State private var address = ""
  @State private var port = "7880"
  @State private var pairingKey = ""
  @State private var client: MirrorClient?
  @State private var error: String?
  @State private var added = false
  @State private var restored = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Remote Mirror Pane").font(.title2.bold())
      if let error = mirrors.credentialError { Text(error).font(.caption).foregroundStyle(.red) }
      if let client, client.isConnected {
        Text("Select a Host pane").foregroundStyle(.secondary)
        if client.panes.isEmpty { Text("No open panes on this Host.") }
        ScrollView {
          VStack(spacing: 8) {
            ForEach(client.panes) { pane in
              Button {
                added = true
                mirrors.add(client, pane: pane)
                dismiss()
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
              }
              .buttonStyle(.plain)
              .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
              .help(pane.title + "\n" + pane.directory)
              .disabled(pane.busy && !client.supportsTakeover)
            }
          }
        }
        .frame(height: min(280, CGFloat(max(1, client.panes.count)) * 76))
        Button("Refresh Panes") { client.refreshPanes() }
      } else {
        Text(
          "Enter the Host address. For a new device, click Add a Device on Host and enter its temporary code."
        )
        .foregroundStyle(.secondary)
        Form {
          TextField("Host IP", text: $address).accessibilityIdentifier("remote-mirror-address")
          TextField("Port", text: $port)
          SecureField("Pairing Code (new devices)", text: $pairingKey)
        }
        .disabled(client?.isConnecting == true)
        if let message = client?.error ?? error {
          Text(message).foregroundStyle(.red).textSelection(.enabled)
        }
      }
      HStack {
        Button("Back") {
          client?.close()
          back()
        }
        Spacer()
        Button("Cancel") { dismiss() }
        if client?.isConnected != true {
          Button(client?.isConnecting == true ? "Connecting…" : "Connect") { connect() }
            .disabled(client?.isConnecting == true)
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(24).frame(width: 420)
    .onAppear {
      guard !restored else { return }
      restored = true
      if let saved = mirrors.savedConnection() {
        address = saved.address
        port = String(saved.port)
        pairingKey = saved.pairingKey
      }
    }
    .onDisappear { if !added { client?.close() } }
    .accessibilityIdentifier("add-remote-mirror-panel")
  }

  private func connect() {
    guard let number = UInt16(port), number > 0,
      IPv4Address(address) != nil || IPv6Address(address) != nil
    else {
      error = "Enter a valid IP address and a port between 1 and 65535."
      return
    }
    client?.close()
    let connection = mirrors.makeClient(address: address, port: number, pairingKey: pairingKey)
    client = connection
    error = nil
    connection.connect()
  }
}
