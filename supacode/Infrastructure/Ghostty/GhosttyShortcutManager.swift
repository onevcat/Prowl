import GhosttyKit
import Observation
import SwiftUI

@MainActor
@Observable
final class GhosttyShortcutManager {
  private let runtime: GhosttyRuntime
  private var generation: Int = 0

  init(runtime: GhosttyRuntime) {
    self.runtime = runtime
    runtime.onConfigChange = { [weak self] in
      self?.refresh()
    }
  }

  func refresh() {
    generation += 1
  }

  var commandPaletteEntries: [GhosttyCommand] {
    _ = generation
    return runtime.commandPaletteEntries()
  }

  func keyboardShortcut(for action: String) -> KeyboardShortcut? {
    _ = generation
    return runtime.keyboardShortcut(for: action)
  }

  func display(for action: String) -> String? {
    guard let shortcut = keyboardShortcut(for: action) else { return nil }
    return shortcut.display
  }
}
