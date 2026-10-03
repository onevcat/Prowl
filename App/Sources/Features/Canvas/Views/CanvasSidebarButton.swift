import ComposableArchitecture
import SwiftUI

struct CanvasSidebarButton: View {
  let store: StoreOf<RepositoriesFeature>
  let isSelected: Bool
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings

  var body: some View {
    Button {
      store.send(.selectCanvas)
    } label: {
      HStack(spacing: 6) {
        Label("Canvas", systemImage: "square.grid.2x2")
          .font(.callout)
          .frame(maxWidth: .infinity, alignment: .leading)
        if commandKeyObserver.isPressed,
          let shortcut = AppShortcuts.display(for: AppShortcuts.CommandID.toggleCanvas, in: resolvedKeybindings)
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
        title: "Canvas",
        commandID: AppShortcuts.CommandID.toggleCanvas,
        in: resolvedKeybindings
      ))
  }
}
