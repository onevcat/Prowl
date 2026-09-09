import SwiftUI

struct RemoteMirrorSidebar: View {
  @Environment(RemoteMirrorStore.self) private var mirrors

  var body: some View {
    if !mirrors.clients.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Remote Mirrors").font(.caption.bold()).foregroundStyle(.secondary)
        ForEach(mirrors.clients) { client in
          Button {
            mirrors.selectedID = client.id
          } label: {
            HStack {
              Image(systemName: client.isConnected ? "network" : "exclamationmark.circle").accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 2) {
                Text(client.selectedPane?.projectName ?? client.selectedPane?.title ?? client.address).lineLimit(1)
                if let subtitle = client.selectedPane?.subtitle {
                  Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
              }
              .help(client.selectedPane.map { $0.title + "\n" + $0.directory } ?? client.address)
              if !client.isConnected {
                Text("Disconnected").font(.caption).foregroundStyle(.orange)
              }
              Spacer(minLength: 0)
            }
            .padding(8)
            .background(
              mirrors.selectedID == client.id ? Color.accentColor.opacity(0.2) : .clear,
              in: RoundedRectangle(cornerRadius: 8))
          }
          .buttonStyle(.plain)
          .contextMenu { Button("Close Mirror") { mirrors.remove(client) } }
        }
      }
      .padding(10)
    }
  }
}

struct RemoteMirrorPaneView: View {
  @Environment(RemoteMirrorStore.self) private var mirrors
  @Bindable var client: MirrorClient

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label(client.selectedPane?.title ?? "Remote Mirror", systemImage: "network")
          .lineLimit(1)
          .help(client.selectedPane.map { $0.title + "\n" + $0.directory } ?? client.address)
        Text("\(client.address):\(String(client.port))").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Label(
          client.isConnected ? "Connected" : "Disconnected",
          systemImage: client.isConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(client.isConnected ? Color.green : Color.orange)
        if client.showsHistory {
          Button("Live Terminal") { client.showsHistory = false }
        } else {
          Button("History") { client.loadHistory(refresh: true) }.disabled(!client.isConnected)
        }
        Button("Close Mirror", systemImage: "xmark") { mirrors.remove(client) }.labelStyle(.iconOnly)
          .help("Disconnect this mirror; the Host program continues running")
      }
      .padding(10)
      Divider()
      if let error = client.error ?? (client.isConnected ? nil : "Connection to Host was lost.") {
        ContentUnavailableView(
          "Mirror Disconnected", systemImage: "network.slash",
          description: Text(
            error
              + " Remote terminal status is unknown. Check Host, then reconnect from Add to Prowl."
          ))
      } else {
        ZStack {
          if let view = client.replica.view {
            MirrorTerminalViewport(surface: view, displaySize: client.replica.displaySize)
              .opacity(client.showsHistory ? 0 : 1)
              .allowsHitTesting(!client.showsHistory)
          } else {
            ProgressView("Opening mirror…")
          }
          if client.showsHistory { history }
        }
      }
    }
    .toolbar { ToolbarItem(placement: .navigation) { MirrorHostButton() } }
    .accessibilityIdentifier("remote-mirror-pane")
  }

  private var history: some View {
    VStack(alignment: .leading) {
      HStack {
        Text("Retained text at time of request").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Refresh") { client.loadHistory(refresh: true) }.disabled(client.isLoadingHistory)
        Button("Load Earlier 200 Lines") { client.loadHistory() }
          .disabled(client.isLoadingHistory || client.historyOffset == 0)
      }
      ScrollView([.horizontal, .vertical]) {
        Text(client.historyLines.joined(separator: "\n"))
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if client.isLoadingHistory { ProgressView() }
    }
    .padding().background(.background)
  }
}
