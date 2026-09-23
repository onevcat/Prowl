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
    .navigationTitle(
      client.selectedPane?.projectName ?? client.selectedPane?.title ?? String(localized: "Remote Mirror")
    )
    .navigationSubtitle(client.selectedPane?.subtitle ?? "")
    .toolbar {
      ToolbarItem(placement: .navigation) { MirrorHostButton() }
      ToolbarItem(placement: .principal) { connectionStatus.padding(.horizontal) }
      ToolbarItemGroup(placement: .primaryAction) {
        recoveryActions
        displaySizeToggle
        historyButton
        Button {
          mirrors.remove(client)
        } label: {
          Label("Disconnect Mirror", systemImage: "personalhotspot.slash")
            .foregroundStyle(.red)
        }
        .help("Disconnect this mirror; the Host program continues running")
        .accessibilityIdentifier("remote-mirror-disconnect")
      }
    }
    .environment(toolbarPopovers)
    .accessibilityIdentifier("remote-mirror-pane")
  }

  private var connectionStatus: some View {
    HStack(spacing: 6) {
      if client.isConnecting {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: client.isSubscribed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .foregroundStyle(client.isSubscribed ? Color.green : Color.orange)
          .accessibilityHidden(true)
      }
      Text(client.statusLabel + " · " + client.address)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .help(client.selectedPane.map { $0.title + "\n" + $0.directory + "\n" + endpoint } ?? endpoint)
    .accessibilityIdentifier("remote-mirror-connection-status")
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
  }

  @ViewBuilder
  private var historyButton: some View {
    if client.showsHistory {
      Button("Live Terminal", systemImage: "terminal") { client.showsHistory = false }
        .help("Return to the live terminal")
    } else {
      Button("History", systemImage: "clock.arrow.circlepath") { client.loadHistory(refresh: true) }
        .disabled(!client.isSubscribed || !client.supportsHistory)
        .help("Read a snapshot of retained terminal text")
        .accessibilityIdentifier("remote-mirror-history")
    }
  }

  private var displaySizeToggle: some View {
    Toggle(isOn: $fitsWindow) {
      Label(
        fitsWindow ? "Fit to Window" : "Original Size",
        systemImage: fitsWindow ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
    }
    .toggleStyle(.button)
    .disabled(client.showsHistory)
    .help(
      fitsWindow
        ? "Fit to Window — click to show Original Size; Host dimensions stay unchanged"
        : "Original Size — click to fit the full terminal to this window; Host dimensions stay unchanged"
    )
    .accessibilityIdentifier("remote-mirror-display-size")
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
