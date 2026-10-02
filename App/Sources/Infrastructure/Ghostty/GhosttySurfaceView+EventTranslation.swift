import AppKit
import Carbon
import GhosttyKit

extension GhosttySurfaceView {
  func translationState(_ event: NSEvent, surface: ghostty_surface_t) -> (
    NSEvent, NSEvent.ModifierFlags
  ) {
    // `characters`-family APIs throw on non-key events, so skip translation for a
    // modifier-only event (otherwise a bare Cmd aborts the send before Ghostty sees it).
    guard event.type == .keyDown || event.type == .keyUp else {
      return (event, event.modifierFlags)
    }
    let translatedModsGhostty = ghostty_surface_key_translation_mods(
      surface, ghosttyMods(event.modifierFlags))
    let translatedMods = appKitMods(translatedModsGhostty)
    var resolved = event.modifierFlags
    for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
      if translatedMods.contains(flag) {
        resolved.insert(flag)
      } else {
        resolved.remove(flag)
      }
    }
    if resolved == event.modifierFlags {
      return (event, resolved)
    }
    let translatedEvent =
      NSEvent.keyEvent(
        with: event.type,
        location: event.locationInWindow,
        modifierFlags: resolved,
        timestamp: event.timestamp,
        windowNumber: event.windowNumber,
        context: nil,
        characters: event.characters(byApplyingModifiers: resolved) ?? "",
        charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
        isARepeat: event.isARepeat,
        keyCode: event.keyCode
      ) ?? event
    return (translatedEvent, resolved)
  }

  func ghosttyKeyEvent(
    _ event: NSEvent,
    action: ghostty_input_action_e,
    originalMods: NSEvent.ModifierFlags,
    translationMods: NSEvent.ModifierFlags,
    composing: Bool = false
  ) -> ghostty_input_key_s {
    var keyEvent: ghostty_input_key_s = .init()
    keyEvent.action = action
    keyEvent.keycode = UInt32(event.keyCode)
    keyEvent.text = nil
    keyEvent.composing = composing
    keyEvent.mods = ghosttyMods(originalMods)
    keyEvent.consumed_mods = ghosttyMods(translationMods.subtracting([.control, .command]))
    keyEvent.unshifted_codepoint = 0
    if event.type == .keyDown || event.type == .keyUp {
      if let chars = event.characters(byApplyingModifiers: []),
        let codepoint = chars.unicodeScalars.first
      {
        keyEvent.unshifted_codepoint = codepoint.value
      }
    }
    return keyEvent
  }

  func suppressKeyboardLayoutChangeKeyUp(_ event: NSEvent) -> Bool {
    guard let suppression = keyboardLayoutChangeKeyUpSuppression else { return false }
    if suppression.isExpired(at: event.timestamp) {
      keyboardLayoutChangeKeyUpSuppression = nil
      return false
    }
    if suppression.suppresses(keyCode: event.keyCode, timestamp: event.timestamp) {
      keyboardLayoutChangeKeyUpSuppression = nil
      return true
    }
    return false
  }

  func ghosttyCharacters(_ event: NSEvent) -> String? {
    GhosttyEventText.characters(for: event)
  }

  func syncPreedit(clearIfNeeded: Bool = true) {
    guard let surface else { return }
    if markedText.length > 0 {
      let str = markedText.string
      let len = str.utf8CString.count
      if len > 0 {
        markedText.string.withCString { ptr in
          ghostty_surface_preedit(surface, ptr, UInt(len - 1))
        }
      }
    } else if clearIfNeeded {
      ghostty_surface_preedit(surface, nil, 0)
    }
  }

  func keyboardLayoutId() -> String? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
      return nil
    }
    guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
      return nil
    }
    let value = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
    return value as String
  }

  func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
    let rawFlags = flags.rawValue
    if (rawFlags & UInt(NX_DEVICERSHIFTKEYMASK)) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if (rawFlags & UInt(NX_DEVICERCTLKEYMASK)) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if (rawFlags & UInt(NX_DEVICERALTKEYMASK)) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if (rawFlags & UInt(NX_DEVICERCMDKEYMASK)) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
    return ghostty_input_mods_e(mods)
  }

  func appKitMods(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if (mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0 { flags.insert(.shift) }
    if (mods.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0 { flags.insert(.control) }
    if (mods.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0 { flags.insert(.option) }
    if (mods.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0 { flags.insert(.command) }
    if (mods.rawValue & GHOSTTY_MODS_CAPS.rawValue) != 0 { flags.insert(.capsLock) }
    return flags
  }
}
