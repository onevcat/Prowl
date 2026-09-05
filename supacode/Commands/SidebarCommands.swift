import ComposableArchitecture
import SwiftUI

struct SidebarCommands: Commands {
  @Bindable var store: StoreOf<AppFeature>
  @FocusedValue(\.toggleLeftSidebarAction) private var toggleLeftSidebarAction
  @FocusedValue(\.revealInSidebarAction) private var revealInSidebarAction

  var body: some Commands {
    CommandGroup(replacing: .sidebar) {
      Button("Toggle Left Sidebar") {
        toggleLeftSidebarAction?()
      }
      .modifier(KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.toggleLeftSidebar)))
      .help(helpText(title: "Toggle Left Sidebar", commandID: AppShortcuts.CommandID.toggleLeftSidebar))
      .disabled(toggleLeftSidebarAction == nil)
      Button("Reveal in Sidebar") {
        revealInSidebarAction?()
      }
      .modifier(KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.revealInSidebar)))
      .help(helpText(title: "Reveal in Sidebar", commandID: AppShortcuts.CommandID.revealInSidebar))
      .disabled(revealInSidebarAction == nil)
      Divider()
      Button("Active Agents") {
        store.send(.repositories(.activeAgents(.togglePanelVisibility)))
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.toggleActiveAgentsPanel))
      )
      .help(helpText(title: "Active Agents", commandID: AppShortcuts.CommandID.toggleActiveAgentsPanel))
      Button("Agent Island") {
        store.send(.repositories(.activeAgents(.islandToggleRoster)))
      }
      .modifier(KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.toggleAgentIsland)))
      .help(helpText(title: "Agent Island", commandID: AppShortcuts.CommandID.toggleAgentIsland))
      .disabled(
        !AgentIslandVisibilityPolicy.isVisible(
          isEnabled: store.settings.agentIslandEnabled,
          onlyShowWithAgents: store.settings.agentIslandOnlyShowWithAgents,
          hasEntries: !store.repositories.activeAgents.entries.isEmpty
        ))
      Button("Select Next Agent") {
        store.send(.repositories(.activeAgents(.selectNextEntry)))
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.selectNextActiveAgent))
      )
      .help(helpText(title: "Select Next Agent", commandID: AppShortcuts.CommandID.selectNextActiveAgent))
      Button("Select Previous Agent") {
        store.send(.repositories(.activeAgents(.selectPreviousEntry)))
      }
      .modifier(
        KeyboardShortcutModifier(
          shortcut: keyboardShortcut(for: AppShortcuts.CommandID.selectPreviousActiveAgent)
        )
      )
      .help(helpText(title: "Select Previous Agent", commandID: AppShortcuts.CommandID.selectPreviousActiveAgent))
      Button("Canvas") {
        store.send(.repositories(.toggleCanvas))
      }
      .modifier(KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.toggleCanvas)))
      .help(helpText(title: "Canvas", commandID: AppShortcuts.CommandID.toggleCanvas))
      Button("Shelf") {
        store.send(.repositories(.toggleShelf))
      }
      .modifier(KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.toggleShelf)))
      .help(helpText(title: "Shelf", commandID: AppShortcuts.CommandID.toggleShelf))
      Button("Select Next Book") {
        store.send(.repositories(.selectNextShelfBook))
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.selectNextShelfBook))
      )
      .help(helpText(title: "Select Next Book", commandID: AppShortcuts.CommandID.selectNextShelfBook))
      Button("Select Previous Book") {
        store.send(.repositories(.selectPreviousShelfBook))
      }
      .modifier(
        KeyboardShortcutModifier(
          shortcut: keyboardShortcut(for: AppShortcuts.CommandID.selectPreviousShelfBook)
        )
      )
      .help(helpText(title: "Select Previous Book", commandID: AppShortcuts.CommandID.selectPreviousShelfBook))
      shelfBookMenuButtons
      Divider()
      Button("Show Diff", systemImage: "plusminus.circle") {
        store.send(.showSelectedWorktreeDiff)
      }
      .modifier(KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.showDiff)))
      .help(helpText(title: "Show Diff", commandID: AppShortcuts.CommandID.showDiff))
      .disabled(store.repositories.selectedDiffTargetID == nil)
      Button("Show Outgoing Changes", systemImage: "arrow.up.right") {
        store.send(.showSelectedWorktreeOutgoingChanges)
      }
      .modifier(KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.outgoingChanges)))
      .help(helpText(title: "Show Outgoing Changes", commandID: AppShortcuts.CommandID.outgoingChanges))
      .disabled(store.repositories.selectedDiffTargetID == nil)
    }
  }

  @ViewBuilder
  private var shelfBookMenuButtons: some View {
    ForEach(Array(AppShortcuts.shelfBookSelectionCommandIDs.enumerated()), id: \.element) { index, commandID in
      let title = "Select Book \(index + 1)"
      Button(title) {
        store.send(.repositories(.selectShelfBook(index + 1)))
      }
      .modifier(KeyboardShortcutModifier(shortcut: keyboardShortcut(for: commandID)))
      .help(helpText(title: title, commandID: commandID))
    }
  }

  private func keyboardShortcut(for commandID: String) -> KeyboardShortcut? {
    store.resolvedKeybindings.keyboardShortcut(for: commandID)
  }

  private func helpText(title: String, commandID: String) -> String {
    if let shortcut = store.resolvedKeybindings.display(for: commandID) {
      return "\(title) (\(shortcut))"
    }
    return title
  }
}

private struct ToggleLeftSidebarActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct RevealInSidebarActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var toggleLeftSidebarAction: FocusedAction<Void>? {
    get { self[ToggleLeftSidebarActionKey.self] }
    set { self[ToggleLeftSidebarActionKey.self] = newValue }
  }

  var revealInSidebarAction: FocusedAction<Void>? {
    get { self[RevealInSidebarActionKey.self] }
    set { self[RevealInSidebarActionKey.self] = newValue }
  }
}
