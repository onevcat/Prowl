import AppKit
import Testing

@testable import supacode

struct CommandKeyObserverTests {
  @Test func shouldShowShortcutsForBareCommandOrControl() {
    #expect(CommandKeyObserver.shouldShowShortcuts(for: [.command]))
    #expect(CommandKeyObserver.shouldShowShortcuts(for: [.control]))
  }

  @Test func shouldNotShowShortcutsForShortcutCombinations() {
    #expect(CommandKeyObserver.shouldShowShortcuts(for: [.command, .shift]) == false)
    #expect(CommandKeyObserver.shouldShowShortcuts(for: [.control, .option]) == false)
    #expect(CommandKeyObserver.shouldShowShortcuts(for: [.command, .control]) == false)
    #expect(CommandKeyObserver.shouldShowShortcuts(for: [.command, .control, .shift]) == false)
  }

  @Test func shouldNotShowShortcutsForNonHintModifiers() {
    #expect(CommandKeyObserver.shouldShowShortcuts(for: []) == false)
    #expect(CommandKeyObserver.shouldShowShortcuts(for: [.shift]) == false)
    #expect(CommandKeyObserver.shouldShowShortcuts(for: [.option]) == false)
    #expect(CommandKeyObserver.shouldShowShortcuts(for: [.shift, .option]) == false)
  }
}
