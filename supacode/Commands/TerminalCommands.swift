import SwiftUI

struct TerminalCommands: Commands {
  let ghosttyShortcuts: GhosttyShortcutManager
  @FocusedValue(\.newTerminalAction) private var newTerminalAction
  @FocusedValue(\.closeSurfaceAction) private var closeSurfaceAction
  @FocusedValue(\.closeTabAction) private var closeTabAction
  @FocusedValue(\.startSearchAction) private var startSearchAction
  @FocusedValue(\.searchSelectionAction) private var searchSelectionAction
  @FocusedValue(\.navigateSearchNextAction) private var navigateSearchNextAction
  @FocusedValue(\.navigateSearchPreviousAction) private var navigateSearchPreviousAction
  @FocusedValue(\.endSearchAction) private var endSearchAction

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("New Terminal") {
        newTerminalAction?()
      }
      .modifier(KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "new_tab")))
      .disabled(newTerminalAction == nil)
      Button("Close") {
        closeSurfaceAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "close_surface"))
      )
      .disabled(closeSurfaceAction == nil)
      Button("Close Tab") {
        closeTabAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "close_tab"))
      )
      .disabled(closeTabAction == nil)
    }
    CommandGroup(after: .textEditing) {
      Button("Find...") {
        startSearchAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "start_search"))
      )
      .disabled(startSearchAction == nil)

      Button("Find Next") {
        navigateSearchNextAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "search:next"))
      )
      .disabled(navigateSearchNextAction == nil)

      Button("Find Previous") {
        navigateSearchPreviousAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "search:previous"))
      )
      .disabled(navigateSearchPreviousAction == nil)

      Divider()

      Button("Hide Find Bar") {
        endSearchAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "end_search"))
      )
      .disabled(endSearchAction == nil)

      Divider()

      Button("Use Selection for Find") {
        searchSelectionAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "search_selection"))
      )
      .disabled(searchSelectionAction == nil)
    }
  }
}

private struct NewTerminalActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var newTerminalAction: (() -> Void)? {
    get { self[NewTerminalActionKey.self] }
    set { self[NewTerminalActionKey.self] = newValue }
  }
}

private struct CloseSurfaceActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var closeSurfaceAction: (() -> Void)? {
    get { self[CloseSurfaceActionKey.self] }
    set { self[CloseSurfaceActionKey.self] = newValue }
  }
}

private struct CloseTabActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var closeTabAction: (() -> Void)? {
    get { self[CloseTabActionKey.self] }
    set { self[CloseTabActionKey.self] = newValue }
  }
}

private struct StartSearchActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var startSearchAction: (() -> Void)? {
    get { self[StartSearchActionKey.self] }
    set { self[StartSearchActionKey.self] = newValue }
  }
}

private struct SearchSelectionActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var searchSelectionAction: (() -> Void)? {
    get { self[SearchSelectionActionKey.self] }
    set { self[SearchSelectionActionKey.self] = newValue }
  }
}

private struct NavigateSearchNextActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var navigateSearchNextAction: (() -> Void)? {
    get { self[NavigateSearchNextActionKey.self] }
    set { self[NavigateSearchNextActionKey.self] = newValue }
  }
}

private struct NavigateSearchPreviousActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var navigateSearchPreviousAction: (() -> Void)? {
    get { self[NavigateSearchPreviousActionKey.self] }
    set { self[NavigateSearchPreviousActionKey.self] = newValue }
  }
}

private struct EndSearchActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var endSearchAction: (() -> Void)? {
    get { self[EndSearchActionKey.self] }
    set { self[EndSearchActionKey.self] = newValue }
  }
}

private struct KeyboardShortcutModifier: ViewModifier {
  let shortcut: KeyboardShortcut?

  func body(content: Content) -> some View {
    if let shortcut {
      content.keyboardShortcut(shortcut)
    } else {
      content
    }
  }
}
