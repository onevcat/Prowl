import SwiftUI
import Testing

@testable import supacode

struct WindowCloseShortcutPolicyTests {
  @Test func closeWindowDoesNotClaimCommandWWhenCloseSurfaceUsesCommandW() {
    let shortcut = WindowCloseShortcutPolicy.closeWindowShortcut(
      closeSurfaceShortcut: KeyboardShortcut("w"),
      closeTabShortcut: nil,
      hasTerminalCloseTarget: true
    )

    #expect(shortcut == nil)
  }

  @Test func closeWindowDoesNotClaimCommandWWhenCloseTabUsesCommandW() {
    let shortcut = WindowCloseShortcutPolicy.closeWindowShortcut(
      closeSurfaceShortcut: KeyboardShortcut("w", modifiers: [.option, .command]),
      closeTabShortcut: KeyboardShortcut("w"),
      hasTerminalCloseTarget: true
    )

    #expect(shortcut == nil)
  }

  @Test func closeWindowKeepsCommandWWhenTerminalCloseActionsUseDifferentShortcuts() {
    let shortcut = WindowCloseShortcutPolicy.closeWindowShortcut(
      closeSurfaceShortcut: KeyboardShortcut("w", modifiers: [.shift, .command]),
      closeTabShortcut: KeyboardShortcut("w", modifiers: [.option, .command]),
      hasTerminalCloseTarget: true
    )

    #expect(shortcut?.key == "w")
    #expect(shortcut?.modifiers == .command)
  }

  @Test func closeWindowKeepsCommandWWhenTerminalHasNoCloseTarget() {
    let shortcut = WindowCloseShortcutPolicy.closeWindowShortcut(
      closeSurfaceShortcut: KeyboardShortcut("w"),
      closeTabShortcut: KeyboardShortcut("w"),
      hasTerminalCloseTarget: false
    )

    #expect(shortcut?.key == "w")
    #expect(shortcut?.modifiers == .command)
  }

  // Closing the last tab of a Shelf book momentarily clears every focused
  // close target while the Shelf advances to the next book. If Close Window
  // is allowed to claim Cmd+W in that window, the next auto-repeated press
  // shuts the whole window. While Shelf still has at least one open book,
  // Cmd+W must stay with the terminal layer.
  @Test func closeWindowYieldsCommandWDuringShelfBookSwitchEvenWithoutFocusedTarget() {
    let shortcut = WindowCloseShortcutPolicy.closeWindowShortcut(
      closeSurfaceShortcut: KeyboardShortcut("w"),
      closeTabShortcut: nil,
      hasTerminalCloseTarget: false,
      shelfHasOpenBooks: true
    )

    #expect(shortcut == nil)
  }

  @Test func closeWindowKeepsCommandWWhenShelfIsEmptyEvenWithoutFocusedTarget() {
    let shortcut = WindowCloseShortcutPolicy.closeWindowShortcut(
      closeSurfaceShortcut: KeyboardShortcut("w"),
      closeTabShortcut: nil,
      hasTerminalCloseTarget: false,
      shelfHasOpenBooks: false
    )

    #expect(shortcut?.key == "w")
    #expect(shortcut?.modifiers == .command)
  }

  @Test func closeWindowKeepsCommandWWhenShelfHasBooksButTerminalUsesDifferentShortcut() {
    let shortcut = WindowCloseShortcutPolicy.closeWindowShortcut(
      closeSurfaceShortcut: KeyboardShortcut("w", modifiers: [.option, .command]),
      closeTabShortcut: nil,
      hasTerminalCloseTarget: false,
      shelfHasOpenBooks: true
    )

    #expect(shortcut?.key == "w")
    #expect(shortcut?.modifiers == .command)
  }

  @Test func closeWindowClaimsCommandWForFocusedSettingsWindow() {
    let shortcut = WindowCloseShortcutPolicy.closeWindowShortcut(
      closeSurfaceShortcut: KeyboardShortcut("w"),
      closeTabShortcut: KeyboardShortcut("w"),
      hasTerminalCloseTarget: true,
      shelfHasOpenBooks: true,
      settingsWindowIsFocused: true
    )

    #expect(shortcut?.key == "w")
    #expect(shortcut?.modifiers == .command)
  }
}
