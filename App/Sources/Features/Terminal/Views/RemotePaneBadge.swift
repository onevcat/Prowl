import SwiftUI

/// The host a pane's foreground `ssh` reaches, in the pane's corner (docs-ai 082, L0
/// item 10). When that `ssh` exits, it says so briefly, then goes away.
struct RemotePaneBadge: View {
  static let endedMarkerDuration: Duration = .seconds(5)

  let indicator: RemotePaneIndicator?
  @State private var isEndedMarkerExpired = false

  var body: some View {
    Group {
      switch indicator {
      case .connected(let host):
        label(Text(verbatim: host), systemImage: "network")
          .accessibilityLabel(Text("Connected to \(host)"))
      case .ended(let host):
        if !isEndedMarkerExpired {
          label(Text("Disconnected from \(host)"), systemImage: "network.slash")
            .transition(.opacity)
        }
      case nil:
        EmptyView()
      }
    }
    .animation(.easeOut(duration: 0.3), value: isEndedMarkerExpired)
    .task(id: indicator) {
      isEndedMarkerExpired = false
      guard case .ended = indicator else { return }
      try? await Task.sleep(for: Self.endedMarkerDuration)
      isEndedMarkerExpired = true
    }
    .allowsHitTesting(false)
  }

  private func label(_ text: Text, systemImage: String) -> some View {
    Label {
      text.lineLimit(1).truncationMode(.middle)
    } icon: {
      Image(systemName: systemImage)
        .imageScale(.small)
        .accessibilityHidden(true)
    }
    .labelStyle(.titleAndIcon)
    .font(.caption2)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(.regularMaterial, in: .capsule)
    .padding(6)
  }
}
