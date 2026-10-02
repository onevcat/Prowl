import SwiftUI

extension KeyboardShortcut {
  var display: String {
    var parts: [String] = []
    if modifiers.contains(.command) { parts.append("⌘") }
    if modifiers.contains(.shift) { parts.append("⇧") }
    if modifiers.contains(.option) { parts.append("⌥") }
    if modifiers.contains(.control) { parts.append("⌃") }
    parts.append(key.display)
    return parts.joined()
  }
}

extension KeyEquivalent {
  var display: String {
    switch self {
    case .delete:
      return "⌫"
    case .return:
      return "↩"
    case .escape:
      return "⎋"
    case .tab:
      return "⇥"
    case .space:
      return "␠"
    case .upArrow:
      return "↑"
    case .downArrow:
      return "↓"
    case .leftArrow:
      return "←"
    case .rightArrow:
      return "→"
    case .home:
      return "↖"
    case .end:
      return "↘"
    case .pageUp:
      return "⇞"
    case .pageDown:
      return "⇟"
    default:
      return String(character).uppercased()
    }
  }
}
