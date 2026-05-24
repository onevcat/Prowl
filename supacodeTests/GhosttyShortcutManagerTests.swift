import Testing

@testable import supacode

@MainActor
struct GhosttyShortcutManagerTests {
  @Test func verticalSplitFallsBackToCommandD() {
    #expect(GhosttyShortcutManager.builtInDefaultDisplay(for: "new_split:right") == "⌘D")
  }

  @Test func horizontalSplitFallsBackToCommandShiftD() {
    #expect(GhosttyShortcutManager.builtInDefaultDisplay(for: "new_split:down") == "⌘⇧D")
  }

  @Test func unknownActionHasNoBuiltInFallback() {
    #expect(GhosttyShortcutManager.builtInDefaultDisplay(for: "new_tab") == nil)
  }

  @Test func previewInstanceReturnsNilForSplitActions() {
    let manager = GhosttyShortcutManager(preview: ())
    #expect(manager.display(for: "new_split:right") == nil)
  }
}
