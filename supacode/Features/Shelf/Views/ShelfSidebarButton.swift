import ComposableArchitecture
import SwiftUI

struct ShelfSidebarButton: View {
  let store: StoreOf<RepositoriesFeature>
  let isSelected: Bool
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings

  var body: some View {
    Button {
      store.send(.toggleShelf)
    } label: {
      HStack(spacing: 6) {
        Label("Shelf", systemImage: "books.vertical")
          .interfaceFont(.callout)
          .frame(maxWidth: .infinity, alignment: .leading)
        if commandKeyObserver.isPressed,
          let shortcut = AppShortcuts.display(for: AppShortcuts.CommandID.toggleShelf, in: resolvedKeybindings)
        {
          ShortcutHintView(text: shortcut, color: .secondary)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 6))
    .help(
      AppShortcuts.helpText(
        title: "Shelf",
        commandID: AppShortcuts.CommandID.toggleShelf,
        in: resolvedKeybindings
      ))
  }
}
