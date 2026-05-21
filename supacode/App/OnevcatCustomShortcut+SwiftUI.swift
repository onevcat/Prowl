import AppKit
import Carbon
import SwiftUI

extension UserCustomShortcut {
  var keyboardShortcut: KeyboardShortcut? {
    guard let keyEquivalent else { return nil }
    return KeyboardShortcut(keyEquivalent, modifiers: modifiers.eventModifiers)
  }

  var keyEquivalent: KeyEquivalent? {
    guard let character = normalizedKeyCharacter else { return nil }
    return KeyEquivalent(character)
  }

  func matches(event: NSEvent) -> Bool {
    keybinding?.matches(event: event) ?? false
  }

  var keybinding: Keybinding? {
    let normalized = normalized()
    guard normalized.isValid else { return nil }
    return Keybinding(key: normalized.key, modifiers: .init(normalized.modifiers))
  }

  private var normalizedKeyCharacter: Character? {
    let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalizedKey.count == 1 else { return nil }
    return normalizedKey.first
  }
}

extension Keybinding {
  func matches(event: NSEvent) -> Bool {
    guard Self.normalizedModifiers(from: event.modifierFlags) == modifiers else { return false }
    guard let eventKey = Self.normalizedKey(for: event) else { return false }
    if eventKey == key {
      return true
    }
    if key.hasPrefix("digit_"), key.dropFirst("digit_".count) == eventKey {
      return true
    }
    return false
  }

  private static func normalizedKey(for event: NSEvent) -> String? {
    switch Int(event.keyCode) {
    case kVK_Return:
      return "return"
    case kVK_LeftArrow:
      return "arrow_left"
    case kVK_RightArrow:
      return "arrow_right"
    case kVK_UpArrow:
      return "arrow_up"
    case kVK_DownArrow:
      return "arrow_down"
    default:
      guard let characters = event.charactersIgnoringModifiers else { return nil }
      let normalized = characters.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard normalized.count == 1 else { return nil }
      return normalized
    }
  }

  private static func normalizedModifiers(from flags: NSEvent.ModifierFlags) -> KeybindingModifiers {
    KeybindingModifiers(
      command: flags.contains(.command),
      shift: flags.contains(.shift),
      option: flags.contains(.option),
      control: flags.contains(.control)
    )
  }
}

extension UserCustomShortcutModifiers {
  var eventModifiers: SwiftUI.EventModifiers {
    var modifiers: SwiftUI.EventModifiers = []
    if command {
      modifiers.insert(.command)
    }
    if shift {
      modifiers.insert(.shift)
    }
    if option {
      modifiers.insert(.option)
    }
    if control {
      modifiers.insert(.control)
    }
    return modifiers
  }
}
