import ComposableArchitecture
import SwiftUI

struct WindowCommands: Commands {
  @Bindable var store: StoreOf<AppFeature>
  let terminalManager: WorktreeTerminalManager
  let ghosttyShortcuts: GhosttyShortcutManager
  let resolvedKeybindings: ResolvedKeybindingMap
  @Environment(\.openWindow) private var openWindow
  @FocusedValue(\.closeSettingsWindowAction) private var closeSettingsWindowAction
  @FocusedValue(\.closeTabAction) private var closeTabAction
  @FocusedValue(\.closeSurfaceAction) private var closeSurfaceAction
  @FocusedValue(\.selectPreviousTerminalTabAction) private var selectPreviousTerminalTabAction
  @FocusedValue(\.selectNextTerminalTabAction) private var selectNextTerminalTabAction
  @FocusedValue(\.selectPreviousTerminalPaneAction) private var selectPreviousTerminalPaneAction
  @FocusedValue(\.selectNextTerminalPaneAction) private var selectNextTerminalPaneAction
  @FocusedValue(\.selectTerminalPaneAboveAction) private var selectTerminalPaneAboveAction
  @FocusedValue(\.selectTerminalPaneBelowAction) private var selectTerminalPaneBelowAction
  @FocusedValue(\.selectTerminalPaneLeftAction) private var selectTerminalPaneLeftAction
  @FocusedValue(\.selectTerminalPaneRightAction) private var selectTerminalPaneRightAction

  var body: some Commands {
    let mainWindowOpenerRegistered = MainWindowOpener.shared.register(openWindow: openWindow)
    let settingsOpenerRegistered = SettingsWindowOpener.shared.register(openWindow: openWindow)
    let closeSurfaceHotkey = ghosttyShortcuts.keyboardShortcut(for: "close_surface")
    let closeTabHotkey = ghosttyShortcuts.keyboardShortcut(for: "close_tab")
    let shelfHasOpenBooks =
      store.repositories.isShelfActive && !store.repositories.openedWorktreeIDs.isEmpty
    let closeWindowShortcut = WindowCloseShortcutPolicy.closeWindowShortcut(
      closeSurfaceShortcut: closeSurfaceHotkey,
      closeTabShortcut: closeTabHotkey,
      hasTerminalCloseTarget: closeTabAction != nil || closeSurfaceAction != nil,
      shelfHasOpenBooks: shelfHasOpenBooks,
      settingsWindowIsFocused: closeSettingsWindowAction != nil
    )

    CommandGroup(replacing: .saveItem) {
      Button("Close Window", systemImage: "xmark") {
        if let closeSettingsWindowAction {
          closeSettingsWindowAction()
        } else {
          NSApplication.shared.keyWindow?.performClose(nil)
        }
      }
      .modifier(
        KeyboardShortcutModifier(
          shortcut: closeWindowShortcut
        )
      )
    }

    let mainWindowTitle = WindowTitle.compute(
      repositories: store.repositories,
      terminalManager: terminalManager
    )
    CommandGroup(replacing: .windowArrangement) {
      Button("Select Previous Tab") {
        selectPreviousTerminalTabAction?()
      }
      .modifier(
        KeyboardShortcutModifier(
          shortcut: resolvedKeybindings.keyboardShortcut(for: AppShortcuts.CommandID.selectPreviousTerminalTab)
        )
      )
      .disabled(selectPreviousTerminalTabAction == nil)

      Button("Select Next Tab") {
        selectNextTerminalTabAction?()
      }
      .modifier(
        KeyboardShortcutModifier(
          shortcut: resolvedKeybindings.keyboardShortcut(for: AppShortcuts.CommandID.selectNextTerminalTab)
        )
      )
      .disabled(selectNextTerminalTabAction == nil)

      Divider()

      Button("Select Previous Pane") {
        selectPreviousTerminalPaneAction?()
      }
      .modifier(
        KeyboardShortcutModifier(
          shortcut: resolvedKeybindings.keyboardShortcut(for: AppShortcuts.CommandID.selectPreviousTerminalPane)
        )
      )
      .disabled(selectPreviousTerminalPaneAction == nil)

      Button("Select Next Pane") {
        selectNextTerminalPaneAction?()
      }
      .modifier(
        KeyboardShortcutModifier(
          shortcut: resolvedKeybindings.keyboardShortcut(for: AppShortcuts.CommandID.selectNextTerminalPane)
        )
      )
      .disabled(selectNextTerminalPaneAction == nil)

      Menu("Select Pane") {
        Button("Select Pane Above") {
          selectTerminalPaneAboveAction?()
        }
        .modifier(
          KeyboardShortcutModifier(
            shortcut: resolvedKeybindings.keyboardShortcut(for: AppShortcuts.CommandID.selectTerminalPaneUp)
          )
        )
        .disabled(selectTerminalPaneAboveAction == nil)

        Button("Select Pane Below") {
          selectTerminalPaneBelowAction?()
        }
        .modifier(
          KeyboardShortcutModifier(
            shortcut: resolvedKeybindings.keyboardShortcut(for: AppShortcuts.CommandID.selectTerminalPaneDown)
          )
        )
        .disabled(selectTerminalPaneBelowAction == nil)

        Button("Select Pane Left") {
          selectTerminalPaneLeftAction?()
        }
        .modifier(
          KeyboardShortcutModifier(
            shortcut: resolvedKeybindings.keyboardShortcut(for: AppShortcuts.CommandID.selectTerminalPaneLeft)
          )
        )
        .disabled(selectTerminalPaneLeftAction == nil)

        Button("Select Pane Right") {
          selectTerminalPaneRightAction?()
        }
        .modifier(
          KeyboardShortcutModifier(
            shortcut: resolvedKeybindings.keyboardShortcut(for: AppShortcuts.CommandID.selectTerminalPaneRight)
          )
        )
        .disabled(selectTerminalPaneRightAction == nil)
      }

      Divider()

      Button(mainWindowTitle) {
        guard mainWindowOpenerRegistered else { return }
        NSApp.surfaceMainWindow()
      }
      .help("Show main window")

    }

    CommandGroup(replacing: .appSettings) {
      Button("Settings...") {
        guard settingsOpenerRegistered else { return }
        _ = SettingsWindowOpener.shared.openSettingsWindow()
      }
      .modifier(
        KeyboardShortcutModifier(
          shortcut: resolvedKeybindings.keyboardShortcut(for: AppShortcuts.CommandID.openSettings)
        )
      )
    }
  }
}

enum WindowCloseShortcutPolicy {
  static func closeWindowShortcut(
    closeSurfaceShortcut: KeyboardShortcut?,
    closeTabShortcut: KeyboardShortcut?,
    hasTerminalCloseTarget: Bool,
    shelfHasOpenBooks: Bool = false,
    settingsWindowIsFocused: Bool = false
  ) -> KeyboardShortcut? {
    // Cmd-W must always close the native singleton Settings window. Its
    // focused scene action is independent of a terminal's retained close
    // targets in the main window.
    if settingsWindowIsFocused {
      return KeyboardShortcut("w")
    }
    // `shelfHasOpenBooks` keeps Cmd+W with the terminal layer through the brief
    // gap between closing a book's last tab and Shelf advancing to the next
    // book. Without it, `hasTerminalCloseTarget` momentarily flips false during
    // that transition, which would let an auto-repeated Cmd+W press fall
    // through to the "Close Window" menu shortcut and shut the window.
    let terminalOwnsCommandW = hasTerminalCloseTarget || shelfHasOpenBooks
    if terminalOwnsCommandW && (isCommandW(closeSurfaceShortcut) || isCommandW(closeTabShortcut)) {
      return nil
    }
    return KeyboardShortcut("w")
  }

  private static func isCommandW(_ shortcut: KeyboardShortcut?) -> Bool {
    shortcut?.key == "w" && shortcut?.modifiers == .command
  }
}

struct KeyboardShortcutModifier: ViewModifier {
  let shortcut: KeyboardShortcut?

  func body(content: Content) -> some View {
    if let shortcut {
      content.keyboardShortcut(shortcut)
    } else {
      content
    }
  }
}

private struct SelectPreviousTerminalTabActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct CloseSettingsWindowActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var closeSettingsWindowAction: FocusedAction<Void>? {
    get { self[CloseSettingsWindowActionKey.self] }
    set { self[CloseSettingsWindowActionKey.self] = newValue }
  }
}

extension FocusedValues {
  var selectPreviousTerminalTabAction: FocusedAction<Void>? {
    get { self[SelectPreviousTerminalTabActionKey.self] }
    set { self[SelectPreviousTerminalTabActionKey.self] = newValue }
  }
}

private struct SelectNextTerminalTabActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var selectNextTerminalTabAction: FocusedAction<Void>? {
    get { self[SelectNextTerminalTabActionKey.self] }
    set { self[SelectNextTerminalTabActionKey.self] = newValue }
  }
}

private struct SelectPreviousTerminalPaneActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var selectPreviousTerminalPaneAction: FocusedAction<Void>? {
    get { self[SelectPreviousTerminalPaneActionKey.self] }
    set { self[SelectPreviousTerminalPaneActionKey.self] = newValue }
  }
}

private struct SelectNextTerminalPaneActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var selectNextTerminalPaneAction: FocusedAction<Void>? {
    get { self[SelectNextTerminalPaneActionKey.self] }
    set { self[SelectNextTerminalPaneActionKey.self] = newValue }
  }
}

private struct SelectTerminalPaneAboveActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var selectTerminalPaneAboveAction: FocusedAction<Void>? {
    get { self[SelectTerminalPaneAboveActionKey.self] }
    set { self[SelectTerminalPaneAboveActionKey.self] = newValue }
  }
}

private struct SelectTerminalPaneBelowActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var selectTerminalPaneBelowAction: FocusedAction<Void>? {
    get { self[SelectTerminalPaneBelowActionKey.self] }
    set { self[SelectTerminalPaneBelowActionKey.self] = newValue }
  }
}

private struct SelectTerminalPaneLeftActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var selectTerminalPaneLeftAction: FocusedAction<Void>? {
    get { self[SelectTerminalPaneLeftActionKey.self] }
    set { self[SelectTerminalPaneLeftActionKey.self] = newValue }
  }
}

private struct SelectTerminalPaneRightActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var selectTerminalPaneRightAction: FocusedAction<Void>? {
    get { self[SelectTerminalPaneRightActionKey.self] }
    set { self[SelectTerminalPaneRightActionKey.self] = newValue }
  }
}
