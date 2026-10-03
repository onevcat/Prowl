import GhosttyKit
import Observation
import SwiftUI

@MainActor
@Observable
final class GhosttyShortcutManager {
  private let runtime: GhosttyRuntime?
  private var generation: Int = 0

  init(runtime: GhosttyRuntime) {
    self.runtime = runtime
    runtime.onConfigChange = { [weak self] in
      self?.refresh()
    }
  }

  #if DEBUG
    /// Preview/test instance with no runtime; shortcut lookups return nil so
    /// views render without a live Ghostty app (mirrors
    /// `WorktreeTerminalManager.preview`).
    init(preview: Void) {
      self.runtime = nil
    }
  #endif

  func refresh() {
    generation += 1
  }

  var commandPaletteEntries: [GhosttyCommand] {
    _ = generation
    return runtime?.commandPaletteEntries() ?? []
  }

  func keyboardShortcut(for action: String) -> KeyboardShortcut? {
    _ = generation
    return runtime?.keyboardShortcut(for: action)
  }

  func display(for action: String) -> String? {
    guard let shortcut = keyboardShortcut(for: action) else { return nil }
    return shortcut.display
  }
}
