import AppKit
import GhosttyKit

/// App-level key dispatch for the moment no terminal surface can take a key:
/// after the last tab of a worktree closed, ⌘Z has no surface to fire from
/// (docs-ai 069.002). Ghostty's own windowless undo goes through the same
/// pair of C calls, so the user's real `undo` / `redo` bindings apply —
/// `performable:` prefixes, unbinds, and additions included — without Prowl
/// reconstructing the binding table.
extension GhosttyRuntime {
  /// Runs the key through Ghostty's app-scoped bindings and reports whether
  /// an `undo` / `redo` action was performed (`onAppUndo` / `onAppRedo`
  /// returned `true`). Other app-scoped actions the key may be bound to are
  /// suppressed for the duration: this route exists for undo alone.
  ///
  /// `ghostty_app_key`'s own result only says a binding matched; the core
  /// discards the action callback's Boolean, so the outcome is read from the
  /// callback instead.
  func performAppUndoRedoBinding(for event: NSEvent) -> Bool {
    guard let app, event.type == .keyDown else { return false }
    var key = Self.appKeyEvent(for: event)
    let text = event.characters ?? ""
    return text.withCString { pointer in
      key.text = text.isEmpty ? nil : pointer
      guard ghostty_app_key_is_binding(app, key) else { return false }
      appUndoRedoOutcome = nil
      isDispatchingUndoRedoKey = true
      defer {
        isDispatchingUndoRedoKey = false
        appUndoRedoOutcome = nil
      }
      _ = ghostty_app_key(app, key)
      return appUndoRedoOutcome ?? false
    }
  }

  /// The action callback's half: records the outcome of an app-scoped
  /// undo/redo, and refuses every other app-scoped action while an undo/redo
  /// key is being dispatched.
  func handleAppScopedAction(_ tag: ghostty_action_tag_e) -> Bool? {
    switch tag {
    case GHOSTTY_ACTION_UNDO:
      let handled = onAppUndo?() ?? false
      appUndoRedoOutcome = handled
      return handled
    case GHOSTTY_ACTION_REDO:
      let handled = onAppRedo?() ?? false
      appUndoRedoOutcome = handled
      return handled
    default:
      return isDispatchingUndoRedoKey ? false : nil
    }
  }

  /// Mirrors `GhosttySurfaceView.ghosttyKeyEvent` for a key that belongs to no
  /// surface: no translation state, no composition.
  static func appKeyEvent(for event: NSEvent) -> ghostty_input_key_s {
    var key = ghostty_input_key_s()
    key.action = GHOSTTY_ACTION_PRESS
    key.keycode = UInt32(event.keyCode)
    key.text = nil
    key.composing = false
    key.mods = mods(from: event.modifierFlags)
    key.consumed_mods = mods(from: event.modifierFlags.subtracting([.control, .command]))
    key.unshifted_codepoint = 0
    if let characters = event.characters(byApplyingModifiers: []),
      let codepoint = characters.unicodeScalars.first
    {
      key.unshifted_codepoint = codepoint.value
    }
    return key
  }

  private static func mods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
    return ghostty_input_mods_e(mods)
  }
}
