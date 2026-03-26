import ComposableArchitecture
import SwiftUI

struct FreestyleSidebarButton: View {
  let store: StoreOf<RepositoriesFeature>
  let isSelected: Bool

  var body: some View {
    Button {
      store.send(.selectFreestyle)
    } label: {
      HStack(spacing: 6) {
        Label("Freestyle", systemImage: "terminal")
          .font(.callout)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 6))
    .help("Freestyle Terminal")
  }
}
