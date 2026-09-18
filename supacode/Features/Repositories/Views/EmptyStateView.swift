import ComposableArchitecture
import SwiftUI

struct EmptyStateView: View {
  let store: StoreOf<RepositoriesFeature>
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings
  @State private var isAddChoicePresented = false

  var body: some View {
    let shortcutDisplay = AppShortcuts.display(
      for: AppShortcuts.CommandID.openRepository, in: resolvedKeybindings)
    ContentUnavailableView {
      Label("Open a repository or folder", systemImage: "folder.badge.plus")
    } description: {
      Text(promptText(shortcutDisplay: shortcutDisplay))
    } actions: {
      Button("Add...") {
        isAddChoicePresented = true
      }
      .persistentPopover(isPresented: $isAddChoicePresented) {
        AddToProwlView(
          dismiss: { isAddChoicePresented = false },
          onBrowse: {
            store.send(.setOpenPanelPresented(true))
          },
          onCloneCompleted: { url in
            store.send(.repositoryManagement(.openRepositories([url])))
          },
          onWorkspace: {
            store.send(.workspaceCreation(.promptRequested))
          },
          onDrop: { urls in
            store.send(.repositoryManagement(.openRepositories(urls)))
          }
        )
      }
      .modifier(
        KeyboardShortcutModifier(
          shortcut: resolvedKeybindings.keyboardShortcut(for: AppShortcuts.CommandID.openRepository)
        )
      )
      .help(
        AppShortcuts.helpText(
          title: "Add Repository",
          commandID: AppShortcuts.CommandID.openRepository,
          in: resolvedKeybindings
        ))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func promptText(shortcutDisplay: String?) -> String {
    if let shortcutDisplay {
      return String(localized: "Press \(shortcutDisplay) or click Add to add one.")
    }
    return String(localized: "Click Add to add one.")
  }
}
