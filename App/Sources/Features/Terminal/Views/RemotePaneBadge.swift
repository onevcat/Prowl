import SwiftUI

/// The host a pane's foreground `ssh` reaches, in the pane's corner (docs-ai 082, L0
/// item 10). When that `ssh` exits, it says so for `RemotePaneIndicator.endedMarkerDuration`
/// after the exit, then goes away; a later mount of the view does not show it again.
struct RemotePaneBadge: View {
  let indicator: RemotePaneIndicator?
  @State private var isEndedMarkerExpired = false

  var body: some View {
    Group {
      switch indicator {
      case .connected(let host, _):
        label(Text(verbatim: host), systemImage: "network")
          .accessibilityLabel(Text("Connected to \(host)"))
      case .ended(let host, _):
        if !isEndedMarkerExpired, indicator?.showsEndedMarker(now: Date()) == true {
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
      guard case .ended(_, let endedAt) = indicator else { return }
      let remaining = endedAt.addingTimeInterval(RemotePaneIndicator.endedMarkerDuration).timeIntervalSinceNow
      if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
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
