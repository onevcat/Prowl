import AppKit
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
    guard let characters = event.charactersIgnoringModifiers else { return false }
    let normalized = characters.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized.count == 1 else { return false }
    guard normalized == String(normalizedKeyCharacter ?? Character(" ")) else { return false }
    return event.modifierFlags.contains(.command) == modifiers.command
      && event.modifierFlags.contains(.shift) == modifiers.shift
      && event.modifierFlags.contains(.option) == modifiers.option
      && event.modifierFlags.contains(.control) == modifiers.control
  }

  private var normalizedKeyCharacter: Character? {
    let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalizedKey.count == 1 else { return nil }
    return normalizedKey.first
  }
}

extension UserCustomShortcutModifiers {
  var eventModifiers: EventModifiers {
    var modifiers: EventModifiers = []
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
