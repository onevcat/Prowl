import Testing

@testable import supacode

struct ShortcutRowActionTests {
  @Test func resolvesResetActionWhenCommandHasOverride() {
    let action = ShortcutRowAction.resolve(
      hasOverride: true,
      resolvedBinding: Keybinding(key: "p", modifiers: .init(command: true))
    )

    #expect(action == .reset)
  }

  @Test func resolvesClearActionWhenDefaultShortcutIsActive() {
    let action = ShortcutRowAction.resolve(
      hasOverride: false,
      resolvedBinding: Keybinding(key: "p", modifiers: .init(command: true))
    )

    #expect(action == .clear)
  }

  @Test func resolvesNoActionWhenShortcutIsAlreadyUnassigned() {
    let action = ShortcutRowAction.resolve(
      hasOverride: false,
      resolvedBinding: nil
    )

    #expect(action == nil)
  }
}
