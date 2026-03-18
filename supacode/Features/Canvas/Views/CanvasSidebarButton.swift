import ComposableArchitecture
import SwiftUI

struct CanvasSidebarButton: View {
  let store: StoreOf<RepositoriesFeature>
  let isSelected: Bool

  var body: some View {
    Button {
      store.send(.selectCanvas)
    } label: {
      Label("Canvas", systemImage: "square.grid.2x2")
        .font(.callout)
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 6))
    .help("Canvas")
  }
}
