import AppKit

@MainActor
final class UserCustomShortcutRegistry {
  static let shared = UserCustomShortcutRegistry()

  private var keybindings: [Keybinding] = []

  private init() {}

  func setKeybindings(_ keybindings: [Keybinding]) {
    self.keybindings = keybindings.filter(\.isValid)
  }

  func matches(event: NSEvent) -> Bool {
    keybindings.contains { $0.matches(event: event) }
  }

  #if DEBUG
    var registeredShortcutsForTesting: [Keybinding] {
      keybindings
    }
  #endif
}
