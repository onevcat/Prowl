import AppKit

/// Classifies editing intent, without reconstructing an application's input buffer.
enum TerminalEditingActivity {
  static func isEditingKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, text: String?) -> Bool {
    if keyCode == 51 || keyCode == 117 { return true }
    guard modifiers.isDisjoint(with: [.command, .control]) else { return false }
    guard let text else { return false }
    return text.unicodeScalars.contains {
      !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
    }
  }
}
