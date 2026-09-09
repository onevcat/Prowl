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

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Remote Mirror Pane").font(.title2.bold())
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
                    Text(pane.title).font(.headline)
                    Text(pane.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  }
                  Spacer()
                  Text(pane.busy ? "In use" : "Mirror")
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
              }
              .buttonStyle(.plain)
              .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
              .help(pane.busy ? "This pane already has a remote mirror" : "Connect to this Host pane")
              .disabled(pane.busy)
            }
          }
        }
        .frame(height: min(280, CGFloat(max(1, client.panes.count)) * 76))
        Button("Refresh Panes") { client.refreshPanes() }
      } else {
        Text("Start Host on the other Mac, then enter its address and pairing key.")
          .foregroundStyle(.secondary)
        Form {
          TextField("Host IP", text: $address).accessibilityIdentifier("remote-mirror-address")
          TextField("Port", text: $port)
          SecureField("Pairing Key", text: $pairingKey)
        }
        .disabled(client?.isConnecting == true)
        if let message = client?.error ?? error { Text(message).foregroundStyle(.red).textSelection(.enabled) }
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
