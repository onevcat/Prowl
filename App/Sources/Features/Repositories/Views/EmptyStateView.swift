import ComposableArchitecture
import SwiftUI

struct EmptyStateView: View {
  let store: StoreOf<RepositoriesFeature>
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings
  @State private var isAddChoicePresented = false
  @State private var isDragTargeted = false

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
          },
          onRemoteFolder: {
            store.send(.addRemoteFolderRequested)
          },
          onNewGroup: {
            store.send(.sidebarGroups(.newEmptyGroupRequested))
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
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        .padding(12)
        .opacity(isDragTargeted ? 1 : 0)
    }
    .dropDestination(for: URL.self) { urls, _ in
      let fileURLs = urls.filter(\.isFileURL)
      guard !fileURLs.isEmpty else { return false }
      store.send(.repositoryManagement(.openRepositories(fileURLs)))
      return true
    } isTargeted: { targeted in
      withAnimation(.easeOut(duration: 0.18)) {
        isDragTargeted = targeted
      }
    }
  }

  private func promptText(shortcutDisplay: String?) -> String {
    if let shortcutDisplay {
      return String(localized: "Press \(shortcutDisplay) or click Add to add one. You can also drop folders here.")
    }
    return String(localized: "Click Add to add one. You can also drop folders here.")
  }
}
