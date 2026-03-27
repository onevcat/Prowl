import SwiftUI

struct TerminalCommands: Commands {
  let ghosttyShortcuts: GhosttyShortcutManager
  @FocusedValue(\.newTerminalAction) private var newTerminalAction
  @FocusedValue(\.canvasNewTerminalAction) private var canvasNewTerminalAction
  @FocusedValue(\.canvasDirectionalNewTerminalLeaderAction) private var canvasDirectionalNewTerminalLeaderAction
  @FocusedValue(\.closeSurfaceAction) private var closeSurfaceAction
  @FocusedValue(\.closeTabAction) private var closeTabAction
  @FocusedValue(\.resetFontSizeAction) private var resetFontSizeAction
  @FocusedValue(\.increaseFontSizeAction) private var increaseFontSizeAction
  @FocusedValue(\.decreaseFontSizeAction) private var decreaseFontSizeAction
  @FocusedValue(\.canvasMoveLeftAction) private var canvasMoveLeftAction
  @FocusedValue(\.canvasMoveDownAction) private var canvasMoveDownAction
  @FocusedValue(\.canvasMoveUpAction) private var canvasMoveUpAction
  @FocusedValue(\.canvasMoveRightAction) private var canvasMoveRightAction
  @FocusedValue(\.startSearchAction) private var startSearchAction
  @FocusedValue(\.searchSelectionAction) private var searchSelectionAction
  @FocusedValue(\.navigateSearchNextAction) private var navigateSearchNextAction
  @FocusedValue(\.navigateSearchPreviousAction) private var navigateSearchPreviousAction
  @FocusedValue(\.endSearchAction) private var endSearchAction

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("New Terminal") {
        if let canvasDirectionalNewTerminalLeaderAction {
          canvasDirectionalNewTerminalLeaderAction()
        } else if let canvasNewTerminalAction {
          canvasNewTerminalAction()
        } else {
          newTerminalAction?()
        }
      }
      .modifier(KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "new_tab")))
      .disabled(
        newTerminalAction == nil
          && canvasNewTerminalAction == nil
          && canvasDirectionalNewTerminalLeaderAction == nil
      )
      Button("Close Terminal") {
        closeSurfaceAction?()
      }
      .modifier(
        KeyboardShortcutModifier(
          shortcut: closeSurfaceAction == nil ? nil : ghosttyShortcuts.keyboardShortcut(for: "close_surface")
        )
      )
      .disabled(closeSurfaceAction == nil)
      Button("Close Terminal Tab") {
        closeTabAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "close_tab"))
      )
      .disabled(closeTabAction == nil)
      Divider()
      Button("Canvas Move Left") {
        canvasMoveLeftAction?()
      }
      .keyboardShortcut("h", modifiers: .option)
      .disabled(canvasMoveLeftAction == nil)
      Button("Canvas Move Down") {
        canvasMoveDownAction?()
      }
      .keyboardShortcut("j", modifiers: .option)
      .disabled(canvasMoveDownAction == nil)
      Button("Canvas Move Up") {
        canvasMoveUpAction?()
      }
      .keyboardShortcut("k", modifiers: .option)
      .disabled(canvasMoveUpAction == nil)
      Button("Canvas Move Right") {
        canvasMoveRightAction?()
      }
      .keyboardShortcut("l", modifiers: .option)
      .disabled(canvasMoveRightAction == nil)
    }
    CommandGroup(after: .toolbar) {
      Divider()
      Button("Reset Font Size", systemImage: "textformat.size") {
        resetFontSizeAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "reset_font_size"))
      )
      .disabled(resetFontSizeAction == nil)

      Button("Increase Font Size", systemImage: "textformat.size.larger") {
        increaseFontSizeAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "increase_font_size:1"))
      )
      .disabled(increaseFontSizeAction == nil)

      Button("Decrease Font Size", systemImage: "textformat.size.smaller") {
        decreaseFontSizeAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "decrease_font_size:1"))
      )
      .disabled(decreaseFontSizeAction == nil)
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
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "navigate_search:next"))
      )
      .disabled(navigateSearchNextAction == nil)

      Button("Find Previous") {
        navigateSearchPreviousAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "navigate_search:previous"))
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
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var newTerminalAction: FocusedAction<Void>? {
    get { self[NewTerminalActionKey.self] }
    set { self[NewTerminalActionKey.self] = newValue }
  }
}

private struct CanvasNewTerminalActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var canvasNewTerminalAction: (() -> Void)? {
    get { self[CanvasNewTerminalActionKey.self] }
    set { self[CanvasNewTerminalActionKey.self] = newValue }
  }
}

private struct CanvasDirectionalNewTerminalLeaderActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var canvasDirectionalNewTerminalLeaderAction: (() -> Void)? {
    get { self[CanvasDirectionalNewTerminalLeaderActionKey.self] }
    set { self[CanvasDirectionalNewTerminalLeaderActionKey.self] = newValue }
  }
}

private struct CanvasNewTerminalUsingPWDActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var canvasNewTerminalUsingPWDAction: (() -> Void)? {
    get { self[CanvasNewTerminalUsingPWDActionKey.self] }
    set { self[CanvasNewTerminalUsingPWDActionKey.self] = newValue }
  }
}

private struct CloseSurfaceActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var closeSurfaceAction: FocusedAction<Void>? {
    get { self[CloseSurfaceActionKey.self] }
    set { self[CloseSurfaceActionKey.self] = newValue }
  }
}

private struct CloseTabActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var closeTabAction: FocusedAction<Void>? {
    get { self[CloseTabActionKey.self] }
    set { self[CloseTabActionKey.self] = newValue }
  }
}

private struct ResetFontSizeActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var resetFontSizeAction: FocusedAction<Void>? {
    get { self[ResetFontSizeActionKey.self] }
    set { self[ResetFontSizeActionKey.self] = newValue }
  }
}

private struct IncreaseFontSizeActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var increaseFontSizeAction: FocusedAction<Void>? {
    get { self[IncreaseFontSizeActionKey.self] }
    set { self[IncreaseFontSizeActionKey.self] = newValue }
  }
}

private struct DecreaseFontSizeActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var decreaseFontSizeAction: FocusedAction<Void>? {
    get { self[DecreaseFontSizeActionKey.self] }
    set { self[DecreaseFontSizeActionKey.self] = newValue }
  }
}
private struct CanvasMoveLeftActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var canvasMoveLeftAction: (() -> Void)? {
    get { self[CanvasMoveLeftActionKey.self] }
    set { self[CanvasMoveLeftActionKey.self] = newValue }
  }
}

private struct CanvasMoveDownActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var canvasMoveDownAction: (() -> Void)? {
    get { self[CanvasMoveDownActionKey.self] }
    set { self[CanvasMoveDownActionKey.self] = newValue }
  }
}

private struct CanvasMoveUpActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var canvasMoveUpAction: (() -> Void)? {
    get { self[CanvasMoveUpActionKey.self] }
    set { self[CanvasMoveUpActionKey.self] = newValue }
  }
}

private struct CanvasMoveRightActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var canvasMoveRightAction: (() -> Void)? {
    get { self[CanvasMoveRightActionKey.self] }
    set { self[CanvasMoveRightActionKey.self] = newValue }
  }
}
private struct StartSearchActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var startSearchAction: FocusedAction<Void>? {
    get { self[StartSearchActionKey.self] }
    set { self[StartSearchActionKey.self] = newValue }
  }
}

private struct SearchSelectionActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var searchSelectionAction: FocusedAction<Void>? {
    get { self[SearchSelectionActionKey.self] }
    set { self[SearchSelectionActionKey.self] = newValue }
  }
}

private struct NavigateSearchNextActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var navigateSearchNextAction: FocusedAction<Void>? {
    get { self[NavigateSearchNextActionKey.self] }
    set { self[NavigateSearchNextActionKey.self] = newValue }
  }
}

private struct NavigateSearchPreviousActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var navigateSearchPreviousAction: FocusedAction<Void>? {
    get { self[NavigateSearchPreviousActionKey.self] }
    set { self[NavigateSearchPreviousActionKey.self] = newValue }
  }
}

private struct EndSearchActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var endSearchAction: FocusedAction<Void>? {
    get { self[EndSearchActionKey.self] }
    set { self[EndSearchActionKey.self] = newValue }
  }
}
