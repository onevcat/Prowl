import ComposableArchitecture
import SwiftUI

struct RemoteMirrorSidebar: View {
  @Environment(RemoteMirrorStore.self) private var mirrors

  @Dependency(FeatureFlags.self) private var featureFlags

  var body: some View {
    if featureFlags.remoteMirror && !mirrors.clients.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Remote Mirrors").font(.caption.bold()).foregroundStyle(.secondary)
        ForEach(mirrors.clients) { client in
          Button {
            mirrors.selectedID = client.id
          } label: {
            HStack {
              Image(systemName: client.isConnected ? "network" : "exclamationmark.circle")
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 2) {
                Text(
                  client.selectedPane?.projectName ?? client.selectedPane?.title ?? client.address
                ).lineLimit(1)
                if let subtitle = client.selectedPane?.subtitle {
                  Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
              }
              .help(client.selectedPane.map { $0.title + "\n" + $0.directory } ?? client.address)
              if !client.isConnected {
                Text(client.statusLabel).font(.caption).foregroundStyle(.orange)
              }
              Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .contentShape(Rectangle())
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
  @State private var toolbarPopovers = ToolbarPopoverCoordinator()
  @Environment(RemoteMirrorStore.self) private var mirrors
  @State private var fitsWindow = true
  @Bindable var client: MirrorClient

  var body: some View {
    VStack(spacing: 0) {
      if let error = client.error {
        Text(error).font(.callout).foregroundStyle(.secondary).padding(10).textSelection(.enabled)
      }
      ZStack {
        if let view = client.replica.view {
          MirrorTerminalViewport(surface: view, displaySize: client.replica.displaySize, fitsWindow: fitsWindow)
            .opacity(client.showsHistory ? 0 : 1)
            .allowsHitTesting(!client.showsHistory)
        } else {
          ProgressView("Opening mirror…")
        }
        if client.showsHistory { history }
      }
    }
    .navigationTitle(client.selectedPane?.projectName ?? "Remote Mirror")
    .toolbar(removing: .title)
    .toolbar {
      ToolbarItem(placement: .navigation) { MirrorHostButton() }
      ToolbarItem(placement: .principal) { connectionSummary }
        .sharedBackgroundVisibility(.hidden)
      ToolbarItemGroup(placement: .primaryAction) {
        recoveryActions
        mirrorOptions
        Button("Disconnect Mirror", systemImage: "personalhotspot.slash") { mirrors.remove(client) }
          .help("Disconnect this mirror; the Host program continues running")
          .accessibilityIdentifier("remote-mirror-disconnect")
      }
    }
    .environment(toolbarPopovers)
    .accessibilityIdentifier("remote-mirror-pane")
  }

  private var connectionSummary: some View {
    HStack(spacing: 8) {
      Image(
        systemName: client.isConnecting
          ? "arrow.trianglehead.2.clockwise"
          : client.isSubscribed ? "checkmark.circle.fill" : "exclamationmark.circle"
      )
      .foregroundStyle(client.isSubscribed ? Color.green : Color.secondary)
      .accessibilityLabel(client.statusLabel)
      .help(client.statusLabel)
      VStack(alignment: .leading, spacing: 1) {
        Text(client.selectedPane?.projectName ?? client.selectedPane?.title ?? "Remote Mirror")
          .font(.headline)
        Text(client.statusLabel + " · " + (client.selectedPane?.subtitle ?? endpoint))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .lineLimit(1)
      .truncationMode(.middle)
    }
    .frame(minWidth: 160, idealWidth: 220, maxWidth: 280, alignment: .leading)
    .help(client.selectedPane.map { $0.title + "\n" + $0.directory + "\n" + endpoint } ?? endpoint)
  }

  @ViewBuilder
  private var recoveryActions: some View {
    if !client.isSubscribed, client.endReason != .paneClosed {
      Button(client.endReason == .takenOver ? "Take Over" : "Retry", systemImage: "arrow.clockwise") {
        client.retry(takeover: client.endReason == .takenOver)
      }
      .disabled(client.isConnecting || (client.endReason == .takenOver && !client.supportsTakeover))
      .help("Reconnect to this pane; Retry never takes control from another device")
      .accessibilityIdentifier("remote-mirror-retry")
    }
    if client.showsHistory {
      Button("Live Terminal", systemImage: "terminal") { client.showsHistory = false }
        .help("Return to the live terminal")
    }
  }

  private var mirrorOptions: some View {
    Menu {
      Text(endpoint)
      Divider()
      Picker("Display Size", selection: $fitsWindow) {
        Text("Fit to Window").tag(true)
        Text("Original Size").tag(false)
      }
      .pickerStyle(.inline)
      .disabled(client.showsHistory)
      .accessibilityIdentifier("remote-mirror-display-size")
      Divider()
      Button("History", systemImage: "clock.arrow.circlepath") { client.loadHistory(refresh: true) }
        .disabled(!client.isSubscribed || !client.supportsHistory || client.showsHistory)
    } label: {
      Label("Mirror Options", systemImage: "ellipsis.circle")
    }
    .menuIndicator(.hidden)
    .help("Mirror options: display size and retained history")
    .accessibilityIdentifier("remote-mirror-options")
  }

  private var endpoint: String { "\(client.address):\(String(client.port))" }

  private var history: some View {
    VStack(alignment: .leading) {
      HStack {
        Text("Retained text at time of request").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Refresh") { client.loadHistory(refresh: true) }
          .disabled(client.isLoadingHistory || !client.isSubscribed)
          .help("Read a new snapshot of retained terminal text")
        Button("Load Earlier 200 Lines") { client.loadHistory() }
          .disabled(client.isLoadingHistory || !client.isSubscribed || client.historyOffset == 0)
          .help("Load the previous page from this retained snapshot")
      }
      if client.historyTruncated {
        Text("Older lines omitted; the first retained line may be incomplete.")
          .font(.caption).foregroundStyle(.secondary)
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
