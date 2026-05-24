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
    // Live lookup wins: `ghostty_config_trigger` returns the real key whenever
    // the action is bound by a plain (non-chained) keybind, so a user's custom
    // rebind is reflected automatically.
    if let shortcut = keyboardShortcut(for: action) {
      return shortcut.display
    }
    // Ghostty deliberately excludes chained / sequenced / performable triggers
    // from its reverse map (they can't be expressed as a single accelerator),
    // so `ghostty_config_trigger` returns nothing for them — e.g. a config that
    // chains `equalize_splits` onto `super+d=new_split:right`. For such known
    // actions, fall back to Ghostty's built-in default binding so the hint
    // still shows. The reverse map can't distinguish "chained on the default
    // key" from "chained on a custom key", so this is best-effort and matches
    // the common case (chaining onto the default key). Preview/test instances
    // have no runtime and keep returning nil so views render without Ghostty.
    guard runtime != nil else { return nil }
    return Self.builtInDefaultShortcuts[action]?.display
  }

  /// Ghostty's built-in default bindings for actions whose live reverse lookup
  /// can come back empty because the user chained/sequenced them (chained
  /// triggers are omitted from Ghostty's reverse map). Display-only; used purely
  /// to surface the key that triggers the action inside the focused surface.
  private static let builtInDefaultShortcuts: [String: KeyboardShortcut] = [
    "new_split:right": KeyboardShortcut("d", modifiers: .command),
    "new_split:down": KeyboardShortcut("d", modifiers: [.command, .shift]),
  ]

  /// Display string for Ghostty's built-in default binding of `action`, if one
  /// is known. Exposed for testing the fallback mapping.
  static func builtInDefaultDisplay(for action: String) -> String? {
    builtInDefaultShortcuts[action]?.display
  }
}
